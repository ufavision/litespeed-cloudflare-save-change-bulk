#!/bin/bash
# =============================================================
#  litespeed-cloudflare-save-change-bulk.sh
#  Bulk "Save Changes" — LiteSpeed Cache › CDN › Cloudflare
#
#  Root cause fix:
#    try_refresh_zone() ไม่ commit ลง DB ใน wp eval CLI context
#    เพราะ LiteSpeed Conf->update() รอ WordPress shutdown hook
#    → แก้โดยยิง Cloudflare API เอง + update_option() โดยตรง
#
#  Option format ใน DB (แยก row):
#    litespeed.conf.cdn-cloudflare        = 1/0
#    litespeed.conf.cdn-cloudflare_key    = API Key / API Token
#    litespeed.conf.cdn-cloudflare_email  = email
#    litespeed.conf.cdn-cloudflare_name   = domain
#    litespeed.conf.cdn-cloudflare_zone   = Zone ID
#    litespeed.conf.cdn-cloudflare_clear  = purge on LSCache purge all
# =============================================================

# ─── ตั้งค่า ─────────────────────────────────────────────────
DELAY_SECONDS=2      # หน่วง (วินาที) ระหว่างเว็บ (ป้องกัน CF rate limit)
WP_TIMEOUT=30        # timeout ต่อเว็บ
MAX_RETRY=3          # retry สูงสุดต่อเว็บ (กรณี CF ไม่ตอบ)
RETRY_DELAY=5        # รอ (วินาที) ก่อน retry
# ─────────────────────────────────────────────────────────────
# หมายเหตุ: รัน Sequential (ไม่ parallel)
# เพราะหลายเว็บอาจใช้ CF account เดียวกัน → parallel = rate limit
# ─────────────────────────────────────────────────────────────

LOG_FILE="/var/log/lscwp-cf-save.log"
LOG_PASS="/var/log/lscwp-cf-save-pass.log"
LOG_FAIL="/var/log/lscwp-cf-save-fail.log"
LOG_SKIP="/var/log/lscwp-cf-save-skip.log"
LOCK_FILE="${LOG_FILE}.lock"

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

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

# ─── ตรวจ WP-CLI ─────────────────────────────────────────────
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI — https://wp-cli.org"
    exit 1
fi

START_TIME=$(date +%s)
log "======================================"
log " BULK CF SAVE CHANGES (LiteSpeed CDN)"
log " เริ่มเวลา   : $(date '+%Y-%m-%d %H:%M:%S')"
log " Delay       : ${DELAY_SECONDS}s | Retry: ${MAX_RETRY}x | RetryDelay: ${RETRY_DELAY}s"
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
        done < <(find "$_uhome" -maxdepth 4 -name "wp-config.php" -print0 2>/dev/null)
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

COUNT=0; SUCCESS=0; FAILED=0; SKIPPED=0

for dir in "${DIRS[@]}"; do
    COUNT=$(( COUNT + 1 ))
    SITE=$(echo "$dir" | sed 's|/home[0-9]*/||;s|/$||')
    LABEL="[$COUNT/$TOTAL] $SITE"

    # ── WP bootstrap 1 ครั้ง: check + ยิง CF API + save ──────
    EVAL_OUT=$(timeout "$WP_TIMEOUT" wp --path="$dir" eval '
        // ── 1. Plugin active? ────────────────────────────────
        if (!is_plugin_active("litespeed-cache/litespeed-cache.php")) {
            echo "STATUS:NOPLUGIN";
            return;
        }

        // ── 2. อ่าน options + ตรวจ ───────────────────────────
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

        // ── 3. ยิง CF API โดยตรง + retry ─────────────────────
        // (fix: LiteSpeed Conf->update() ไม่ commit ใน CLI context)
        $max_retry   = (int) getenv("MAX_RETRY")   ?: 3;
        $retry_delay = (int) getenv("RETRY_DELAY") ?: 5;
        $zone_id     = "";
        $zone_name   = "";
        $attempt     = 0;
        $cf_error    = "";

        // รองรับทั้ง Global API Key (email+key) และ API Token (key เท่านั้น)
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
                $cf_error = "curl_error:" . $curl_err;
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

            $cf_error = "zone_empty_in_response";
            if ($attempt < $max_retry) sleep($retry_delay);
        }

        // ── 4. บันทึกลง DB โดยตรง (ข้าม LiteSpeed Conf cache) ─
        if ($zone_id) {
            update_option("litespeed.conf.cdn-cloudflare_zone", $zone_id);
            update_option("litespeed.conf.cdn-cloudflare_name", $zone_name);
        }

        // ── 5. Verify ─────────────────────────────────────────
        $verify = trim((string) get_option("litespeed.conf.cdn-cloudflare_zone", ""));
        printf("STATUS:DONE\tZONE:%s\tDOMAIN:%s\tEMAIL:%s\tKEY:%s\tATTEMPT:%d\tERROR:%s",
            $verify, $zone_name ?: $name, $email, substr($key,0,8), $attempt, $cf_error
        );
    ' --allow-root 2>/dev/null \
      MAX_RETRY="$MAX_RETRY" RETRY_DELAY="$RETRY_DELAY")

    # ── parse output ─────────────────────────────────────────
    STATUS=$(  echo "$EVAL_OUT" | grep -oP '(?<=STATUS:)\w+')

    case "$STATUS" in
        NOPLUGIN)
            log "⏭  SKIP (plugin ไม่ active): $LABEL"
            log_result skip "$SITE | plugin ไม่ active"
            SKIPPED=$(( SKIPPED + 1 ))
            ;;
        CF_OFF)
            log "⏭  SKIP (Cloudflare ปิดอยู่): $LABEL"
            log_result skip "$SITE | cdn-cloudflare=OFF"
            SKIPPED=$(( SKIPPED + 1 ))
            ;;
        NO_CRED)
            KL=$(echo "$EVAL_OUT" | grep -oP '(?<=KEY_LEN:)\d+')
            NM=$(echo "$EVAL_OUT" | grep -oP '(?<=NAME:)[^\t]*')
            log "⏭  SKIP (ไม่มี API Key/Domain): $LABEL | name='$NM' key_len=$KL"
            log_result skip "$SITE | ไม่มี API Key หรือ Domain | name='$NM' key_len=$KL"
            SKIPPED=$(( SKIPPED + 1 ))
            ;;
        DONE)
            ZONE=$(    echo "$EVAL_OUT" | grep -oP '(?<=ZONE:)[^\t]*')
            DOMAIN=$(  echo "$EVAL_OUT" | grep -oP '(?<=DOMAIN:)[^\t]*')
            EMAIL=$(   echo "$EVAL_OUT" | grep -oP '(?<=EMAIL:)[^\t]*')
            KPFX=$(    echo "$EVAL_OUT" | grep -oP '(?<=KEY:)[^\t]*')
            ATTEMPT=$( echo "$EVAL_OUT" | grep -oP '(?<=ATTEMPT:)\d+')
            CFERROR=$( echo "$EVAL_OUT" | grep -oP '(?<=ERROR:)[^\t]*')

            if [[ -n "$ZONE" ]]; then
                log "✅ PASS: $LABEL | domain=$DOMAIN | zone=$ZONE | attempt=${ATTEMPT}/${MAX_RETRY}"
                log_result pass "$SITE | domain=$DOMAIN | zone=$ZONE | email=$EMAIL | key=${KPFX}... | attempt=${ATTEMPT}/${MAX_RETRY}"
                SUCCESS=$(( SUCCESS + 1 ))
            else
                log "❌ FAIL: $LABEL | domain=$DOMAIN | attempt=${ATTEMPT}/${MAX_RETRY} | error=$CFERROR"
                log_result fail "$SITE | zone=(empty) | domain=$DOMAIN | email=$EMAIL | key=${KPFX}... | attempt=${ATTEMPT}/${MAX_RETRY} | error=$CFERROR"
                FAILED=$(( FAILED + 1 ))
            fi
            sleep "$DELAY_SECONDS"
            ;;
        *)
            log "❌ FAIL (wp error/timeout): $LABEL"
            log_result fail "$SITE | wp eval ล้มเหลว | ${EVAL_OUT:0:120}"
            FAILED=$(( FAILED + 1 ))
            ;;
    esac
done

# ─── สรุป ────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

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
