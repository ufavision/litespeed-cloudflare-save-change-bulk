#!/bin/bash
# =============================================================
#  litespeed-cloudflare-save-change-bulk.sh
#  Bulk "Save Changes" — LiteSpeed Cache › CDN › Cloudflare
#
#  Root cause fix:
#    try_refresh_zone() ไม่ commit ลง DB ใน wp eval CLI context
#    เพราะ LiteSpeed Conf->update() รอ WordPress shutdown hook
#    → แก้โดยยิง Cloudflare API เอง + update_option() โดยตรง
# =============================================================

# ─── ตั้งค่า ─────────────────────────────────────────────────
MAX_JOBS=5       # parallel jobs (แนะนำ 5 — ปลอดภัยสำหรับหลาย CF account)
WP_TIMEOUT=30    # timeout ต่อเว็บ (วินาที)
MAX_RETRY=3      # retry สูงสุดต่อเว็บ (กรณี CF ไม่ตอบ)
RETRY_DELAY=5    # รอ (วินาที) ก่อน retry
# ─────────────────────────────────────────────────────────────

LOG_FILE="/var/log/lscwp-cf-save.log"
LOG_PASS="/var/log/lscwp-cf-save-pass.log"
LOG_FAIL="/var/log/lscwp-cf-save-fail.log"
LOG_SKIP="/var/log/lscwp-cf-save-skip.log"
LOG_MISMATCH="/var/log/lscwp-cf-save-mismatch.log"  # domain ใน plugin ไม่ตรงกับ folder
LOG_NOTCF="/var/log/lscwp-cf-save-notcf.log"          # domain ไม่อยู่ใน CF account
LOG_HASZONE="/var/log/lscwp-cf-save-haszone.log"      # มี zone อยู่แล้ว ข้ามไป
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-cf-$$"
mkdir -p "$RESULT_DIR"

log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$ts] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

log_result() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$1" in
        pass) ( flock 201; echo "[$ts] $2" >> "$LOG_PASS" ) 201>"${LOG_FILE}.pass.lock" ;;
        fail) ( flock 202; echo "[$ts] $2" >> "$LOG_FAIL" ) 202>"${LOG_FILE}.fail.lock" ;;
        skip)     ( flock 203; echo "[$ts] $2" >> "$LOG_SKIP"     ) 203>"${LOG_FILE}.skip.lock" ;;
        mismatch) ( flock 204; echo "[$ts] $2" >> "$LOG_MISMATCH" ) 204>"${LOG_FILE}.mismatch.lock" ;;
        notcf)    ( flock 205; echo "[$ts] $2" >> "$LOG_NOTCF"    ) 205>"${LOG_FILE}.notcf.lock" ;;
        haszone)  ( flock 206; echo "[$ts] $2" >> "$LOG_HASZONE" ) 206>"${LOG_FILE}.haszone.lock" ;;
    esac
}

cleanup() {
    wait
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE" "${LOG_FILE}.pass.lock" "${LOG_FILE}.fail.lock" "${LOG_FILE}.skip.lock" "${LOG_FILE}.mismatch.lock" "${LOG_FILE}.notcf.lock" "${LOG_FILE}.haszone.lock"
}
trap cleanup EXIT

# ─── ตรวจ WP-CLI ─────────────────────────────────────────────
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI — https://wp-cli.org"
    exit 1
fi

# ─── ล้าง log ทุกครั้งก่อนรัน (เก็บเฉพาะ run ล่าสุด) ────────
> "$LOG_FILE"
> "$LOG_PASS"
> "$LOG_FAIL"
> "$LOG_SKIP"
> "$LOG_MISMATCH"
> "$LOG_NOTCF"
> "$LOG_HASZONE"

START_TIME=$(date +%s)
log "======================================"
log " BULK CF SAVE CHANGES (LiteSpeed CDN)"
log " เริ่มเวลา   : $(date '+%Y-%m-%d %H:%M:%S')"
log " Jobs        : $MAX_JOBS | Retry: ${MAX_RETRY}x | RetryDelay: ${RETRY_DELAY}s"
log "======================================"

# ─── ค้นหา WordPress ทุกเว็บ ─────────────────────────────────
declare -A _SEEN
DIRS=()

# แหล่งที่ 1: WHM — /etc/trueuserdomains
if [[ -f /etc/trueuserdomains ]]; then
    while IFS=' ' read -r _dom _usr _rest; do
        _usr="${_usr%:}"
        [[ -z "$_usr" ]] && continue
        _uhome=$(getent passwd "$_usr" 2>/dev/null | cut -d: -f6)
        [[ -d "$_uhome" ]] || continue
        while IFS= read -r -d '' _wpc; do
            _d="$(dirname "$_wpc")/"
            [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
        done < <(find "$_uhome" -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)
    done < /etc/trueuserdomains
fi

# แหล่งที่ 2: Scan /home /home2 /home3 /home4 /home5 /usr/home
for _base in /home /home2 /home3 /home4 /home5 /usr/home; do
    [[ -d "$_base" ]] || continue
    while IFS= read -r -d '' _wpc; do
        _d="$(dirname "$_wpc")/"
        [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
    done < <(find "$_base" -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)
done

TOTAL=${#DIRS[@]}
log "พบ WordPress : $TOTAL เว็บ"
log "======================================"

# ─── ฟังก์ชัน process แต่ละเว็บ (รัน parallel) ───────────────
process_site() {
    local dir="$1"
    local COUNT="$2"
    local TOTAL="$3"
    local SITE UNIQ
    SITE=$(echo "$dir" | sed 's|/home[0-9]*/||;s|/$||')
    UNIQ="${BASHPID}_$(date +%s%N)"
    local LABEL="[$COUNT/$TOTAL] $SITE"

    _log() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$ts] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }
    _log_r() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        case "$1" in
            pass) ( flock 201; echo "[$ts] $2" >> "$LOG_PASS" ) 201>"${LOG_FILE}.pass.lock" ;;
            fail) ( flock 202; echo "[$ts] $2" >> "$LOG_FAIL" ) 202>"${LOG_FILE}.fail.lock" ;;
            skip) ( flock 203; echo "[$ts] $2" >> "$LOG_SKIP" ) 203>"${LOG_FILE}.skip.lock" ;;
        esac
    }

    local MR="$MAX_RETRY"
    local RD="$RETRY_DELAY"

    EVAL_OUT=$(timeout "$WP_TIMEOUT" wp --path="$dir" eval '
        // ── 1. Plugin active? ────────────────────────────────
        if (!is_plugin_active("litespeed-cache/litespeed-cache.php")) {
            echo "STATUS:NOPLUGIN"; return;
        }

        // ── 2. อ่าน options + ตรวจ ───────────────────────────
        $enabled = get_option("litespeed.conf.cdn-cloudflare", "0");
        $key     = trim((string) get_option("litespeed.conf.cdn-cloudflare_key",   ""));
        $email   = trim((string) get_option("litespeed.conf.cdn-cloudflare_email", ""));
        $name    = trim((string) get_option("litespeed.conf.cdn-cloudflare_name",  ""));

        if (!$enabled || $enabled === "0" || $enabled === false) {
            echo "STATUS:CF_OFF"; return;
        }
        if (!$key || !$name) {
            printf("STATUS:NO_CRED\tKEY_LEN:%d\tNAME:%s", strlen($key), $name); return;
        }

        // ── 3. ตรวจ domain ใน plugin ตรงกับ folder ไหม ────────
        // เช่น folder=101tiger.org แต่ name=ambauto900.com → ผิด
        $folder = basename(rtrim(ABSPATH, "/"));
        // กรณี public_html → ใช้ชื่อ domain จาก folder parent
        if ($folder === "public_html") {
            $folder = basename(dirname(rtrim(ABSPATH, "/")));
        }
        $name_clean = preg_replace("#^https?://#", "", rtrim($name, "/"));
        if ($folder && $name_clean && $folder !== $name_clean) {
            printf("STATUS:MISMATCH\tFOLDER:%s\tDOMAIN:%s\tEMAIL:%s\tKEY:%s",
                $folder, $name_clean, $email, substr($key,0,8));
            return;
        }

        // ── 4. มี zone อยู่แล้ว → skip ไม่ต้องยิง CF API ──────
        $existing_zone = trim((string) get_option("litespeed.conf.cdn-cloudflare_zone", ""));
        if ($existing_zone) {
            printf("STATUS:HAS_ZONE\tZONE:%s\tDOMAIN:%s", $existing_zone, $name);
            return;
        }

        // ── 4. ยิง CF API โดยตรง + retry ─────────────────────
        $max_retry   = '"$MR"';
        $retry_delay = '"$RD"';
        $zone_id     = "";
        $zone_name   = "";
        $attempt     = 0;
        $cf_error    = "";

        $is_token = (strlen($key) > 37 && strpos($email, "@") === false);
        $headers  = $is_token
            ? ["Authorization: Bearer $key", "Content-Type: application/json"]
            : ["X-Auth-Email: $email", "X-Auth-Key: $key", "Content-Type: application/json"];

        while ($attempt < $max_retry) {
            $attempt++;
            $url = "https://api.cloudflare.com/client/v4/zones?status=active&match=all&name=" . urlencode($name);
            $ch  = curl_init();
            curl_setopt($ch, CURLOPT_URL,            $url);
            curl_setopt($ch, CURLOPT_HTTPHEADER,     $headers);
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_TIMEOUT,        10);
            curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
            $raw      = curl_exec($ch);
            $http     = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $curl_err = curl_error($ch);
            curl_close($ch);

            if ($curl_err) {
                $cf_error = "curl:" . $curl_err;
                if ($attempt < $max_retry) { sleep($retry_delay); continue; }
                break;
            }
            $res = json_decode($raw, true);
            if ($http !== 200 || empty($res["success"])) {
                $cf_error = "http:" . $http . " err:" . json_encode($res["errors"] ?? []);
                if ($attempt < $max_retry) { sleep($retry_delay); continue; }
                break;
            }
            $zone_id   = $res["result"][0]["id"]   ?? "";
            $zone_name = $res["result"][0]["name"] ?? $name;
            if ($zone_id) break;
            $cf_error = "zone_empty";
            if ($attempt < $max_retry) sleep($retry_delay);
        }

        // ── 4. บันทึกลง DB โดยตรง ────────────────────────────
        if ($zone_id) {
            update_option("litespeed.conf.cdn-cloudflare_zone", $zone_id);
            update_option("litespeed.conf.cdn-cloudflare_name", $zone_name);
        }

        // ── 5. Verify ─────────────────────────────────────────
        $verify = trim((string) get_option("litespeed.conf.cdn-cloudflare_zone", ""));
        printf("STATUS:DONE\tZONE:%s\tDOMAIN:%s\tEMAIL:%s\tKEY:%s\tATTEMPT:%d\tERROR:%s",
            $verify, $zone_name ?: $name, $email, substr($key,0,8), $attempt, $cf_error
        );
    ' --allow-root 2>/dev/null)

    local STATUS
    STATUS=$(echo "$EVAL_OUT" | grep -oP '(?<=STATUS:)\w+')

    case "$STATUS" in
        MISMATCH)
            local MF MD ME MK
            MF=$(echo "$EVAL_OUT" | grep -oP '(?<=FOLDER:)[^\t]*')
            MD=$(echo "$EVAL_OUT" | grep -oP '(?<=DOMAIN:)[^\t]*')
            ME=$(echo "$EVAL_OUT" | grep -oP '(?<=EMAIL:)[^\t]*')
            MK=$(echo "$EVAL_OUT" | grep -oP '(?<=KEY:)[^\t]*')
            _log  "⚠️  MISMATCH: $LABEL | folder=$MF แต่ domain=$MD"
            _log_r mismatch "$SITE | folder=$MF | domain=$MD | email=$ME | key=${MK}..."
            touch "${RESULT_DIR}/mismatch_${UNIQ}"
            ;;
        HAS_ZONE)
            local HZ HD
            HZ=$(echo "$EVAL_OUT" | grep -oP '(?<=ZONE:)[^\t]*')
            HD=$(echo "$EVAL_OUT" | grep -oP '(?<=DOMAIN:)[^\t]*')
            _log  "✔️  HAS_ZONE: $LABEL | domain=$HD | zone=$HZ"
            _log_r haszone "$SITE | domain=$HD | zone=$HZ"
            touch "${RESULT_DIR}/haszone_${UNIQ}"
            ;;
        NOPLUGIN)
            _log  "⏭  SKIP (plugin ไม่ active): $LABEL"
            _log_r skip "$SITE | plugin ไม่ active"
            touch "${RESULT_DIR}/skip_${UNIQ}"
            ;;
        CF_OFF)
            _log  "⏭  SKIP (Cloudflare ปิดอยู่): $LABEL"
            _log_r skip "$SITE | cdn-cloudflare=OFF"
            touch "${RESULT_DIR}/skip_${UNIQ}"
            ;;
        NO_CRED)
            local KL NM
            KL=$(echo "$EVAL_OUT" | grep -oP '(?<=KEY_LEN:)\d+')
            NM=$(echo "$EVAL_OUT" | grep -oP '(?<=NAME:)[^\t]*')
            _log  "⏭  SKIP (ไม่มี API Key/Domain): $LABEL | name='$NM' key_len=$KL"
            _log_r skip "$SITE | ไม่มี API Key หรือ Domain | name='$NM' key_len=$KL"
            touch "${RESULT_DIR}/skip_${UNIQ}"
            ;;
        DONE)
            local ZONE DOMAIN EMAIL KPFX ATTEMPT CFERROR
            ZONE=$(    echo "$EVAL_OUT" | grep -oP '(?<=ZONE:)[^\t]*')
            DOMAIN=$(  echo "$EVAL_OUT" | grep -oP '(?<=DOMAIN:)[^\t]*')
            EMAIL=$(   echo "$EVAL_OUT" | grep -oP '(?<=EMAIL:)[^\t]*')
            KPFX=$(    echo "$EVAL_OUT" | grep -oP '(?<=KEY:)[^\t]*')
            ATTEMPT=$( echo "$EVAL_OUT" | grep -oP '(?<=ATTEMPT:)\d+')
            CFERROR=$( echo "$EVAL_OUT" | grep -oP '(?<=ERROR:)[^\t]*')

            if [[ -n "$ZONE" ]]; then
                _log  "✅ PASS: $LABEL | domain=$DOMAIN | zone=$ZONE | attempt=${ATTEMPT}/${MAX_RETRY}"
                _log_r pass "$SITE | domain=$DOMAIN | zone=$ZONE | email=$EMAIL | key=${KPFX}... | attempt=${ATTEMPT}/${MAX_RETRY}"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            elif [[ "$CFERROR" == "zone_empty" ]]; then
                _log  "🌐 NOTCF: $LABEL | domain=$DOMAIN | domain ไม่อยู่ใน CF account"
                _log_r notcf "$SITE | domain=$DOMAIN | email=$EMAIL | key=${KPFX}... | domain ไม่อยู่ใน CF account"
                touch "${RESULT_DIR}/notcf_${UNIQ}"
            else
                _log  "❌ FAIL: $LABEL | domain=$DOMAIN | attempt=${ATTEMPT}/${MAX_RETRY} | error=$CFERROR"
                _log_r fail "$SITE | zone=(empty) | domain=$DOMAIN | email=$EMAIL | key=${KPFX}... | attempt=${ATTEMPT}/${MAX_RETRY} | error=$CFERROR"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            ;;
        *)
            _log  "❌ FAIL (wp error/timeout): $LABEL"
            _log_r fail "$SITE | wp eval ล้มเหลว | ${EVAL_OUT:0:120}"
            touch "${RESULT_DIR}/fail_${UNIQ}"
            ;;
    esac
}

export -f process_site
export LOG_FILE LOCK_FILE LOG_PASS LOG_FAIL LOG_SKIP RESULT_DIR WP_TIMEOUT MAX_RETRY RETRY_DELAY

# ─── รัน parallel ────────────────────────────────────────────
declare -a PIDS=()
COUNT=0
for dir in "${DIRS[@]}"; do
    COUNT=$(( COUNT + 1 ))
    process_site "$dir" "$COUNT" "$TOTAL" &
    PIDS+=($!)
    if (( ${#PIDS[@]} >= MAX_JOBS )); then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

# ─── สรุป ────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
SUCCESS=$(   find "$RESULT_DIR" -name "pass_*"     2>/dev/null | wc -l)
FAILED=$(    find "$RESULT_DIR" -name "fail_*"     2>/dev/null | wc -l)
SKIPPED=$(   find "$RESULT_DIR" -name "skip_*"     2>/dev/null | wc -l)
MISMATCHED=$(find "$RESULT_DIR" -name "mismatch_*" 2>/dev/null | wc -l)
NOTCF=$(     find "$RESULT_DIR" -name "notcf_*"    2>/dev/null | wc -l)
HASZONE=$(   find "$RESULT_DIR" -name "haszone_*"  2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด      : $TOTAL เว็บ"
log " ✅ Pass          : $SUCCESS เว็บ"
log " ✔️  Has Zone       : $HASZONE เว็บ  (มี zone อยู่แล้ว ข้ามไป)"
log " ❌ Fail          : $FAILED เว็บ  (CF API error/timeout)"
log " 🌐 Not in CF     : $NOTCF เว็บ  (domain ไม่อยู่ใน CF account)"
log " ⚠️  Domain ผิด   : $MISMATCHED เว็บ  (domain ใน plugin ไม่ตรงกับ folder)"
log " ⏭  Skip          : $SKIPPED เว็บ  (plugin ปิด / ไม่มี key)"
log " เวลาที่ใช้       : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log "======================================"
log " Log รวม         : $LOG_FILE"
log " ✅ Pass          : $LOG_PASS"
log " ✔️  Has Zone       : $LOG_HASZONE"
log " ❌ Fail          : $LOG_FAIL"
log " 🌐 Not in CF     : $LOG_NOTCF"
log " ⚠️  Domain ผิด   : $LOG_MISMATCH"
log " ⏭  Skip          : $LOG_SKIP"
log "======================================"

# ดูรายละเอียดแต่ละ category ได้จาก log files ด้านบน

exit 0
