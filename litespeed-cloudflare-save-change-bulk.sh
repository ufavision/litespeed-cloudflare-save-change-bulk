#!/bin/bash
# =============================================================
#  litespeed-cloudflare-save-change-bulk.sh
#  Bulk "Save Changes" — LiteSpeed Cache › CDN › Cloudflare
#
#  Core method (ยืนยันจากการทดสอบจริง):
#    LiteSpeed\CDN\Cloudflare::cls()->try_refresh_zone()
#    → เรียก Cloudflare API fetch zone ตรงๆ เหมือนกด Save Changes
#
#  Option format ใน DB (แยก row):
#    litespeed.conf.cdn-cloudflare        = 1/0
#    litespeed.conf.cdn-cloudflare_key    = API Key / API Token
#    litespeed.conf.cdn-cloudflare_email  = email
#    litespeed.conf.cdn-cloudflare_name   = domain
#    litespeed.conf.cdn-cloudflare_zone   = Zone ID (auto หลัง save)
#    litespeed.conf.cdn-cloudflare_clear  = purge on LSCache purge all
# =============================================================

# ─── ตั้งค่า ─────────────────────────────────────────────────
DELAY_SECONDS=1      # หน่วง (วินาที) หลัง save (ป้องกัน CF rate limit)
WP_TIMEOUT=120       # timeout ต่อเว็บ (รองรับ retry 3x + delay 5s)
RAM_PER_JOB_MB=150   # RAM ประมาณต่อ parallel job
MAX_JOBS_HARD=20     # จำนวน parallel jobs สูงสุด
# ─────────────────────────────────────────────────────────────

LOG_FILE="/var/log/lscwp-cf-save.log"
LOG_PASS="/var/log/lscwp-cf-save-pass.log"
LOG_FAIL="/var/log/lscwp-cf-save-fail.log"
LOG_SKIP="/var/log/lscwp-cf-save-skip.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-cf-$$"

log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$ts] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

log_result() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$1" in
        pass) echo "[$ts] $2" >> "$LOG_PASS" ;;
        fail) echo "[$ts] $2" >> "$LOG_FAIL" ;;
        skip) echo "[$ts] $2" >> "$LOG_SKIP" ;;
    esac
}

cleanup() {
    wait
    rm -rf "$RESULT_DIR"
    rm -f  "$LOCK_FILE"
}
trap cleanup EXIT
mkdir -p "$RESULT_DIR"

# ─── ตรวจ WP-CLI ─────────────────────────────────────────────
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI — https://wp-cli.org"
    exit 1
fi

# ─── คำนวณ MAX_JOBS ──────────────────────────────────────────
CPU_CORES=$(nproc 2>/dev/null || echo 2)
TOTAL_RAM_MB=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 512)
MAX_JOBS_RAM=$(( TOTAL_RAM_MB / RAM_PER_JOB_MB ))
MAX_JOBS=$(( CPU_CORES < MAX_JOBS_RAM ? CPU_CORES : MAX_JOBS_RAM ))
[ "$MAX_JOBS" -lt 1 ]               && MAX_JOBS=1
[ "$MAX_JOBS" -gt "$MAX_JOBS_HARD" ] && MAX_JOBS=$MAX_JOBS_HARD

START_TIME=$(date +%s)
log "======================================"
log " BULK CF SAVE CHANGES (LiteSpeed CDN)"
log " เริ่มเวลา   : $(date '+%Y-%m-%d %H:%M:%S')"
log " Delay       : ${DELAY_SECONDS}s  |  Jobs: $MAX_JOBS"
log "======================================"

# ─── ค้นหา WordPress ทุกเว็บ ─────────────────────────────────
declare -A _SEEN
DIRS=()

# แหล่งที่ 1: WHM — /etc/trueuserdomains
# format: "domain.com: cpanelusername"
if [[ -f /etc/trueuserdomains ]]; then
    while IFS=' ' read -r _dom _usr _rest; do
        _usr="${_usr%:}"
        [[ -z "$_usr" ]] && continue
        _uhome=$(getent passwd "$_usr" 2>/dev/null | cut -d: -f6)
        [[ -d "$_uhome" ]] || continue
        while IFS= read -r -d '' _wpc; do
            _d="$(dirname "$_wpc")/"
            [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
        done < <(find "$_uhome" -maxdepth 3 -name "wp-config.php" -print0 2>/dev/null)
    done < /etc/trueuserdomains
fi

# แหล่งที่ 2: Scan /home /home2 /home3 /home4 /home5 /usr/home
for _base in /home /home2 /home3 /home4 /home5 /usr/home; do
    [[ -d "$_base" ]] || continue
    while IFS= read -r -d '' _wpc; do
        _d="$(dirname "$_wpc")/"
        [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
    done < <(find "$_base" -maxdepth 4 -name "wp-config.php" -print0 2>/dev/null)
done

TOTAL=${#DIRS[@]}
log "พบ WordPress : $TOTAL เว็บ"
log "======================================"

# ─── ฟังก์ชัน process แต่ละเว็บ ─────────────────────────────
process_site() {
    local dir="$1"
    local SITE UNIQ
    SITE=$(echo "$dir" | sed 's|/home[0-9]*/||;s|/$||')
    UNIQ="${BASHPID}_$(date +%s%N)"

    _log() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$ts] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }
    _log_r() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        case "$1" in
            pass) echo "[$ts] $2" >> "$LOG_PASS" ;;
            fail) echo "[$ts] $2" >> "$LOG_FAIL" ;;
            skip) echo "[$ts] $2" >> "$LOG_SKIP" ;;
        esac
    }

    # ── WP bootstrap 1 ครั้ง: check + save + verify ──────────
    local EVAL_OUT
    EVAL_OUT=$(timeout "$WP_TIMEOUT" wp --path="$dir" eval '
        // ── 1. Plugin active? ────────────────────────────────
        if (!is_plugin_active("litespeed-cache/litespeed-cache.php")) {
            echo "STATUS:NOPLUGIN";
            return;
        }

        // ── 2. ตรวจ Cloudflare เปิด + มี credentials ─────────
        $enabled = get_option("litespeed.conf.cdn-cloudflare", "0");
        $key     = trim((string) get_option("litespeed.conf.cdn-cloudflare_key",   ""));
        $email   = trim((string) get_option("litespeed.conf.cdn-cloudflare_email", ""));
        $name    = trim((string) get_option("litespeed.conf.cdn-cloudflare_name",  ""));

        if (!$enabled || $enabled === "0" || $enabled === false) {
            echo "STATUS:CF_OFF";
            return;
        }
        if (!$key || !$name) {
            printf("STATUS:NO_CRED\tKEY_LEN:%d\tNAME:%s", strlen($key), $name);
            return;
        }

        // ── 3. Save Changes + Retry จนกว่าจะได้ zone ────────────
        // retry สูงสุด 3 ครั้ง, รอ 5 วินาทีระหว่าง retry
        // (เหมือนกด Save Changes ซ้ำจนกว่า CF จะตอบกลับ)
        $max_retry   = 3;
        $retry_delay = 5;
        $zone        = "";
        $attempt     = 0;

        while ($attempt < $max_retry) {
            $attempt++;
            LiteSpeed\CDN\Cloudflare::cls()->try_refresh_zone();
            $zone = trim((string) get_option("litespeed.conf.cdn-cloudflare_zone", ""));
            if ($zone) break;
            if ($attempt < $max_retry) sleep($retry_delay);
        }

        // ── 4. Verify zone หลัง save ──────────────────────────
        $name2 = trim((string) get_option("litespeed.conf.cdn-cloudflare_name", $name));
        printf("STATUS:DONE\tZONE:%s\tDOMAIN:%s\tEMAIL:%s\tKEY:%s\tATTEMPT:%d",
            $zone, $name2, $email, substr($key, 0, 8), $attempt
        );
    ' --allow-root 2>/dev/null)

    # ── parse output (tab-separated, ไม่ใช้ python3) ─────────
    local STATUS
    STATUS=$(echo "$EVAL_OUT" | grep -oP '(?<=STATUS:)\w+')

    case "$STATUS" in
        NOPLUGIN)
            _log  "⏭  SKIP (plugin ไม่ active): $SITE"
            _log_r skip "$SITE | plugin ไม่ active"
            touch "${RESULT_DIR}/skip_${UNIQ}"
            ;;
        CF_OFF)
            _log  "⏭  SKIP (Cloudflare ปิดอยู่): $SITE"
            _log_r skip "$SITE | cdn-cloudflare=OFF"
            touch "${RESULT_DIR}/skip_${UNIQ}"
            ;;
        NO_CRED)
            local KL NM
            KL=$(echo "$EVAL_OUT" | grep -oP '(?<=KEY_LEN:)\d+')
            NM=$(echo "$EVAL_OUT" | grep -oP '(?<=NAME:)[^\t]*')
            _log  "⏭  SKIP (ไม่มี API Key/Domain): $SITE | name='$NM' key_len=$KL"
            _log_r skip "$SITE | ไม่มี API Key หรือ Domain | name='$NM' key_len=$KL"
            touch "${RESULT_DIR}/skip_${UNIQ}"
            ;;
        DONE)
            local ZONE DOMAIN EMAIL KPFX
            ZONE=$(   echo "$EVAL_OUT" | grep -oP '(?<=ZONE:)[^\t]*')
            DOMAIN=$( echo "$EVAL_OUT" | grep -oP '(?<=DOMAIN:)[^\t]*')
            EMAIL=$(  echo "$EVAL_OUT" | grep -oP '(?<=EMAIL:)[^\t]*')
            KPFX=$(   echo "$EVAL_OUT" | grep -oP '(?<=KEY:)[^\t]*')

            local ATTEMPT
            ATTEMPT=$(echo "$EVAL_OUT" | grep -oP '(?<=ATTEMPT:)\d+')
            if [[ -n "$ZONE" ]]; then
                _log  "✅ PASS: $SITE | domain=$DOMAIN | zone=$ZONE | attempt=${ATTEMPT}/3"
                _log_r pass "$SITE | domain=$DOMAIN | zone=$ZONE | email=$EMAIL | key=${KPFX}... | attempt=${ATTEMPT}/3"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            else
                _log  "❌ FAIL (zone ว่าง หลัง retry ${ATTEMPT}/3 ครั้ง — credentials ผิด / CF ไม่ตอบ): $SITE | domain=$DOMAIN"
                _log_r fail "$SITE | zone=(empty) | domain=$DOMAIN | email=$EMAIL | key=${KPFX}... | attempt=${ATTEMPT}/3"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            sleep "$DELAY_SECONDS"
            ;;
        *)
            _log  "❌ FAIL (wp error/timeout): $SITE"
            _log_r fail "$SITE | wp eval ล้มเหลว | ${EVAL_OUT:0:120}"
            touch "${RESULT_DIR}/fail_${UNIQ}"
            ;;
    esac
}

export -f process_site
export LOG_FILE LOCK_FILE LOG_PASS LOG_FAIL LOG_SKIP RESULT_DIR WP_TIMEOUT DELAY_SECONDS

# ─── รัน parallel ────────────────────────────────────────────
declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    process_site "$dir" &
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
SUCCESS=$(find "$RESULT_DIR" -name "pass_*" 2>/dev/null | wc -l)
FAILED=$( find "$RESULT_DIR" -name "fail_*" 2>/dev/null | wc -l)
SKIPPED=$(find "$RESULT_DIR" -name "skip_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด   : $TOTAL เว็บ"
log " ✅ Pass       : $SUCCESS เว็บ"
log " ❌ Fail       : $FAILED เว็บ"
log " ⏭  Skip       : $SKIPPED เว็บ"
log " เวลาที่ใช้    : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log "======================================"
log " Log รวม      : $LOG_FILE"
log " ✅ Pass       : $LOG_PASS"
log " ❌ Fail       : $LOG_FAIL"
log " ⏭  Skip       : $LOG_SKIP"
log "======================================"

if (( FAILED > 0 )); then
    echo ""
    echo "━━━ รายการ FAIL ━━━"
    cat "$LOG_FAIL"
fi

exit 0
