# servis_kontrol v2.0

Sistemdeki servisleri izleyen, duran servisi otomatik başlatan ve sizi anında haberdar eden bash script.

[![Shell](https://img.shields.io/badge/Shell-Bash-green)](https://www.gnu.org/software/bash/)
[![systemd](https://img.shields.io/badge/init-systemd-blue)](https://systemd.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Ne Yapar?

Crontab üzerinde her dakika çalışır. `SERVICES` dizisindeki her servis için `systemctl is-active` ile durum kontrolü yapar. Servis durmuşsa `systemctl start` ile başlatır, sonucu size mail ve/veya Slack üzerinden bildirir. Servis bir türlü başlamıyorsa ayrı bir "müdahale gerekli" bildirimi gönderir.

---

## v1 → v2 Ne Değişti?

| Özellik | v1 | v2 |
|---|---|---|
| **Servis tespiti** | `ps \| grep` (güvenilmez) | `systemctl is-active` ✅ |
| **Başlatma** | `/sbin/service` (SysV) | `systemctl start` ✅ |
| **Çoklu servis** | Yok, tek servis | `SERVICES` dizisi ✅ |
| **Log** | Yok | `/var/log/servis_kontrol.log` ✅ |
| **Lock file** | Yok | Çakışan cron önleme ✅ |
| **Retry sayacı** | Yok | N denemeden sonra "patladı" bildirimi ✅ |
| **Slack** | Yok | Webhook desteği ✅ |
| **Dry-run** | Yok | `--dry-run` test modu ✅ |
| **SIEM** | Yok | `--json-log` JSON çıktı ✅ |

---

## Gereksinimler

- Bash 4.0+
- systemd (CentOS 7+, Ubuntu 16.04+, Debian 8+)
- `mail` komutu — mail bildirimi için opsiyonel (`mailutils` veya `postfix`)
- `curl` — Slack bildirimi için opsiyonel

---

## Kurulum

### 1. Dosyayı Kopyalayın

```bash
mkdir -p /etc/servis_kontrol
cp servis_kontrol.sh /etc/servis_kontrol/
chmod +x /etc/servis_kontrol/servis_kontrol.sh
```

### 2. Ayarları Düzenleyin

```bash
nano /etc/servis_kontrol/servis_kontrol.sh
```

Doldurulması gereken değerler:

```bash
# İzlenecek servisler
SERVICES=(
    "mysql"
    "nginx"
    "php8.2-fpm"
)

# Bildirim e-postası
EMAIL="admin@sirketiniz.com"

# Slack Webhook (opsiyonel)
SLACK_WEBHOOK="https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

### 3. Önce Dry-Run ile Test Edin

```bash
/etc/servis_kontrol/servis_kontrol.sh --dry-run
```

Çıktıda servislerin durumu görünür, hiçbir aksiyon alınmaz, bildirim gönderilmez.

### 4. Crontab'a Ekleyin

```bash
crontab -e
```

```
* * * * * /etc/servis_kontrol/servis_kontrol.sh >> /dev/null 2>&1
```

---

## Komut Satırı Parametreleri

```bash
# Normal çalıştırma
./servis_kontrol.sh

# Aksiyon almadan test et
./servis_kontrol.sh --dry-run

# SIEM uyumlu JSON log çıkışı
./servis_kontrol.sh --json-log

# İkisi birden
./servis_kontrol.sh --dry-run --json-log
```

---

## Log Çıktısı

**Normal format:**
```
2026-04-22T15:00:01+0300 [INFO] [mysql] Çalışıyor ✓
2026-04-22T15:00:01+0300 [INFO] [nginx] Çalışıyor ✓
2026-04-22T15:01:01+0300 [WARN] [mysql] Servis durdu, başlatılıyor...
2026-04-22T15:01:06+0300 [INFO] [mysql] Başarıyla başlatıldı (deneme: 1)
2026-04-22T15:05:01+0300 [ERROR] [mysql] Başlatılamadı! (deneme: 3/3)
```

**JSON format (`--json-log`):**
```json
{"timestamp":"2026-04-22T15:00:01+0300","severity":"INFO","host":"web01","service":"mysql","message":"Çalışıyor ✓"}
{"timestamp":"2026-04-22T15:01:01+0300","severity":"WARN","host":"web01","service":"mysql","message":"Servis durdu, başlatılıyor..."}
```

---

## Bildirimler

### Mail Bildirimi

`mailutils` veya `postfix` kurulu olması gerekir:

```bash
# Debian/Ubuntu
apt install mailutils

# CentOS/RHEL
yum install mailx
```

### Slack Bildirimi

1. [Slack API](https://api.slack.com/apps) → **Create New App** → **Incoming Webhooks**
2. Webhook URL'yi `SLACK_WEBHOOK` değerine yapıştırın

Servis başarıyla restart edildiğinde:
> 🖥 **web01** — ✅ mysql yeniden başlatıldı

Servis başlatılamadığında:
> 🖥 **web01** — 🚨 mysql BAŞLATILEMIYOR — MÜDAHALE GEREKLİ

---

## Retry Mekanizması

`MAX_RETRIES` (varsayılan: 3) sayısına kadar her cron çalışmasında restart denenir. Bu sayıya ulaşıldığında "patladı" bildirimi gönderilir. Servis bir sonraki başarılı çalışmada aktif gelirse sayaç sıfırlanır.

```
1. dakika → start denemesi 1 → başlatılamadı → normal bildirim
2. dakika → start denemesi 2 → başlatılamadı → normal bildirim  
3. dakika → start denemesi 3 → başlatılamadı → "MÜDAHALE GEREKLİ" bildirimi
```

---

## systemd ile Birlikte Kullanım

Bu script ile systemd'nin kendi `Restart=` özelliği birbirini dışlamaz, birlikte kullanılabilir:

```ini
# /etc/systemd/system/mysql.service.d/override.conf
[Service]
Restart=always
RestartSec=5
```

```bash
systemctl daemon-reload
```

**İş bölümü:** systemd anlık çökmelerde hızlıca restart eder (saniyeler içinde). Bu script ise uzun vadeli izleme, restart sayacı ve bildirim için çalışır. systemd'nin restart edip edemediğini de bu script loglar.

---

## SIEM Entegrasyonu

`--json-log` moduyla Splunk, Wazuh, QRadar veya Elastic Stack'e beslenebilir.

**Splunk Universal Forwarder:**
```
[monitor:///var/log/servis_kontrol.log]
sourcetype = _json
index = linux_ops
```

**Wazuh:** `/var/ossec/etc/ossec.conf` içine log dosyasını ekleyin, `severity:ERROR` alanı üzerinden alert kuralı yazın.

---

## Güvenlik Notları

- Script root yetkisiyle çalışır (`systemctl start` için gerekli). Dosya izinlerini kısıtlayın: `chmod 700 /etc/servis_kontrol/servis_kontrol.sh`
- Log dosyasını logrotate ile döndürün, aksi halde zamanla büyür
- Slack Webhook URL'sini script içinde değil, ayrı bir `credentials` dosyasında saklayabilirsiniz: `source /etc/servis_kontrol/.credentials`

---

## logrotate Konfigürasyonu

```
/var/log/servis_kontrol.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

```bash
cp servis_kontrol.logrotate /etc/logrotate.d/servis_kontrol
```

---

## Yazar

**Hamza Şamlıoğlu**  
Managing Partner, [Privia Security](https://priviasecurity.com)  
GitHub: [@teakolik](https://github.com/teakolik)  
LinkedIn: [linkedin.com/in/teakolik](https://www.linkedin.com/in/teakolik/)
