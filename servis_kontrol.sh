#!/usr/bin/env bash
# =============================================================================
#  servis_kontrol v2.0
# =============================================================================
#  Yazar   : Hamza Şamlıoğlu <hamza@priviasecurity.com>
#  GitHub  : https://github.com/teakolik
#  Lisans  : MIT
# =============================================================================
#
#  v1 → v2 DEĞİŞİKLİKLER:
#   - ps|grep tespiti → systemctl is-active (güvenilir)
#   - /sbin/service   → systemctl start
#   - Tek servis      → çoklu servis dizisi
#   - Log desteği     → /var/log/servis_kontrol.log
#   - Lock file       → çakışan cron instance önleme
#   - Retry mekanizması → start sonrası N saniye bekleyip tekrar kontrol
#   - Slack webhook   → mail'e ek/alternatif bildirim
#   - Dry-run modu    → --dry-run ile test
#   - JSON log modu   → --json-log ile SIEM uyumu
#   - Uptime takibi   → her run'da toplam restart sayısı loglanır
#
# =============================================================================
# KURULUM
# =============================================================================
#
#  1) Dosyayı kopyalayın:
#       cp servis_kontrol.sh /etc/servis_kontrol/servis_kontrol.sh
#       chmod +x /etc/servis_kontrol/servis_kontrol.sh
#
#  2) Aşağıdaki AYARLAR bölümünü düzenleyin.
#
#  3) Crontab (her dakika):
#       * * * * * /etc/servis_kontrol/servis_kontrol.sh >> /dev/null 2>&1
#
# =============================================================================

set -euo pipefail

# =============================================================================
# AYARLAR
# =============================================================================

# İzlenecek servisler (systemd servis adları)
SERVICES=(
    "mysql"
    "nginx"
    # "php8.2-fpm"
    # "redis"
    # "postgresql"
)

# Bildirim e-postası (boş bırakılırsa mail gönderilmez)
EMAIL="teakolik@teakolik.com"

# Slack Webhook URL (boş bırakılırsa Slack bildirimi gönderilmez)
# Dashboard > Apps > Incoming Webhooks > Add
SLACK_WEBHOOK=""

# Start sonrası servisin ayağa kalkması için bekleme süresi (saniye)
RESTART_WAIT=5

# Maksimum restart denemesi (bu sayıyı geçince "patladı" maili gider)
MAX_RETRIES=3

# Log dosyası
LOG_FILE="/var/log/servis_kontrol.log"

# Restart sayacı dosyası
COUNTER_FILE="/var/run/servis_kontrol_counters"

# Lock dosyası
LOCK_FILE="/var/run/servis_kontrol.lock"

# JSON log modu (SIEM entegrasyonu)
JSON_LOG=false

# Dry-run modu
DRY_RUN=false

# =============================================================================
# ARG PARSE
# =============================================================================

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --json-log) JSON_LOG=true ;;
        --help|-h)
            echo "Kullanım: $0 [--dry-run] [--json-log]"
            echo "  --dry-run   Servisleri başlatmadan, bildirim göndermeden test et"
            echo "  --json-log  SIEM uyumlu JSON log çıkışı"
            exit 0
            ;;
    esac
done

# =============================================================================
# LOGLAMA
# =============================================================================

log() {
    local SEVERITY="$1"
    local SERVICE="$2"
    local MSG="$3"
    local TS
    TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local HOST
    HOST="$(hostname -s)"

    if [ "$JSON_LOG" = true ]; then
        local ESCAPED
        ESCAPED=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"timestamp":"%s","severity":"%s","host":"%s","service":"%s","message":"%s"}\n' \
            "$TS" "$SEVERITY" "$HOST" "$SERVICE" "$ESCAPED" >> "$LOG_FILE"
    else
        printf '%s [%s] [%s] %s\n' "$TS" "$SEVERITY" "$SERVICE" "$MSG" >> "$LOG_FILE"
    fi

    # ERROR ve WARN ayrıca stderr'e
    if [ "$SEVERITY" = "ERROR" ] || [ "$SEVERITY" = "WARN" ]; then
        printf '%s [%s] [%s] %s\n' "$TS" "$SEVERITY" "$SERVICE" "$MSG" >&2
    fi
}

# =============================================================================
# BİLDİRİM
# =============================================================================

send_mail() {
    local SUBJECT="$1"
    local BODY="$2"
    [ -z "$EMAIL" ] && return 0
    [ "$DRY_RUN" = true ] && { log "INFO" "notify" "[DRY-RUN] Mail atılmadı: $SUBJECT"; return 0; }
    command -v mail >/dev/null 2>&1 || { log "WARN" "notify" "mail komutu bulunamadı, bildirim atlanadı"; return 1; }
    echo "$BODY" | mail -s "$SUBJECT" "$EMAIL"
}

send_slack() {
    local MSG="$1"
    [ -z "$SLACK_WEBHOOK" ] && return 0
    [ "$DRY_RUN" = true ] && { log "INFO" "notify" "[DRY-RUN] Slack bildirimi atıldı"; return 0; }
    command -v curl >/dev/null 2>&1 || return 1
    local ESCAPED
    ESCAPED=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "$SLACK_WEBHOOK" \
        -H 'Content-type: application/json' \
        --data "{\"text\":\"$ESCAPED\"}" \
        --max-time 10 >/dev/null 2>&1 || true
}

notify() {
    local SUBJECT="$1"
    local BODY="$2"
    send_mail "$SUBJECT" "$BODY"
    send_slack "🖥 *$(hostname -s)* — $SUBJECT\n$BODY"
}

# =============================================================================
# RESTART SAYACI
# =============================================================================

get_counter() {
    local SVC="$1"
    touch "$COUNTER_FILE"
    grep -E "^${SVC}=" "$COUNTER_FILE" 2>/dev/null | cut -d'=' -f2 || echo 0
}

increment_counter() {
    local SVC="$1"
    local CUR
    CUR=$(get_counter "$SVC")
    local NEW=$((CUR + 1))
    local TMP
    TMP=$(mktemp)
    grep -vE "^${SVC}=" "$COUNTER_FILE" > "$TMP" 2>/dev/null || true
    echo "${SVC}=${NEW}" >> "$TMP"
    mv "$TMP" "$COUNTER_FILE"
    echo "$NEW"
}

reset_counter() {
    local SVC="$1"
    local TMP
    TMP=$(mktemp)
    grep -vE "^${SVC}=" "$COUNTER_FILE" > "$TMP" 2>/dev/null || true
    mv "$TMP" "$COUNTER_FILE"
}

# =============================================================================
# SERVİS KONTROLÜ
# =============================================================================

is_active() {
    local SVC="$1"
    systemctl is-active --quiet "$SVC" 2>/dev/null
}

start_service() {
    local SVC="$1"
    [ "$DRY_RUN" = true ] && { log "INFO" "$SVC" "[DRY-RUN] systemctl start atlandı"; return 0; }
    systemctl start "$SVC" 2>/dev/null
}

check_service() {
    local SVC="$1"

    if is_active "$SVC"; then
        log "INFO" "$SVC" "Çalışıyor ✓"
        reset_counter "$SVC"
        return 0
    fi

    # Servis durdu
    log "WARN" "$SVC" "Servis durdu, başlatılıyor..."

    local ATTEMPT
    ATTEMPT=$(increment_counter "$SVC")

    start_service "$SVC"
    sleep "$RESTART_WAIT"

    if is_active "$SVC"; then
        log "INFO" "$SVC" "Başarıyla başlatıldı (deneme: ${ATTEMPT})"
        notify \
            "✅ [$(hostname -s)] $SVC yeniden başlatıldı" \
            "Servis: $SVC\nSunucu: $(hostname -f)\nZaman: $(date)\nDeneme: ${ATTEMPT}\n\nServis otomatik olarak başlatıldı."
    else
        log "ERROR" "$SVC" "Başlatılamadı! (deneme: ${ATTEMPT}/${MAX_RETRIES})"

        if [ "$ATTEMPT" -ge "$MAX_RETRIES" ]; then
            notify \
                "🚨 [$(hostname -s)] $SVC BAŞLATILEMIYOR — MÜDAHALE GEREKLİ" \
                "Servis: $SVC\nSunucu: $(hostname -f)\nZaman: $(date)\nDeneme: ${ATTEMPT}\n\nsystemctl status $SVC çıktısı:\n$(systemctl status "$SVC" 2>&1 | head -20)"
        fi
    fi
}

# =============================================================================
# LOCK MEKANİZMASI
# =============================================================================

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local OLD_PID
        OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
        if kill -0 "$OLD_PID" 2>/dev/null; then
            log "WARN" "lock" "Zaten çalışıyor (PID: ${OLD_PID}). Çıkılıyor."
            exit 0
        else
            log "INFO" "lock" "Eski lock temizlendi (PID: ${OLD_PID})"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# =============================================================================
# DOĞRULAMA
# =============================================================================

validate() {
    command -v systemctl >/dev/null 2>&1 || {
        echo "HATA: systemctl bulunamadı. Bu script systemd gerektiriyor."
        exit 1
    }

    if [ ${#SERVICES[@]} -eq 0 ]; then
        echo "HATA: SERVICES dizisi boş. En az bir servis tanımlayın."
        exit 1
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" "$COUNTER_FILE" 2>/dev/null || true
}

# =============================================================================
# ANA DÖNGÜ
# =============================================================================

main() {
    validate
    acquire_lock
    trap release_lock EXIT INT TERM

    log "INFO" "system" "servis_kontrol v2.0 başlatıldı | Servisler: ${SERVICES[*]}"

    [ "$DRY_RUN" = true ] && log "INFO" "system" "=== DRY-RUN MODU ==="

    for svc in "${SERVICES[@]}"; do
        check_service "$svc"
    done

    log "INFO" "system" "Tamamlandı."
}

main
