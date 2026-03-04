# litespeed-cloudflare-save-change-bulk.sh

> Bulk **"Save Changes"** — LiteSpeed Cache › CDN › Tab Cloudflare › Cloudflare Setting  
> รันครั้งเดียว ครอบคลุมทุกเว็บใน cPanel/WHM server

---

## วิธีรัน

```bash
bash <(curl -s https://raw.githubusercontent.com/ufavision/litespeed-cloudflare-save-change-bulk/main/litespeed-cloudflare-save-change-bulk.sh)
```

หรือดาวน์โหลดก่อน:

```bash
curl -O https://raw.githubusercontent.com/ufavision/litespeed-cloudflare-save-change-bulk/main/litespeed-cloudflare-save-change-bulk.sh
chmod +x litespeed-cloudflare-save-change-bulk.sh
bash litespeed-cloudflare-save-change-bulk.sh
```

---

## ทำอะไร

เทียบเท่ากับการกดปุ่ม **Save Changes** บนหน้า Admin UI ของทุกเว็บ:

```
LiteSpeed Cache › CDN › Tab Cloudflare › Cloudflare Setting › Save Changes
```

### Core method (ยืนยันจากการทดสอบจริง)

```php
LiteSpeed\CDN\Cloudflare::cls()->try_refresh_zone()
```

method นี้ยิง Cloudflare API โดยตรงเพื่อ fetch และ update Zone ID —  
ตรงกับสิ่งที่เกิดขึ้นเมื่อกด Save Changes บน Admin UI จริงๆ

### ขั้นตอนต่อเว็บ

| # | สิ่งที่ทำ | เทียบกับ Admin UI |
|---|----------|-------------------|
| 1 | ตรวจ `litespeed-cache` plugin active | — |
| 2 | ตรวจ `cdn-cloudflare = 1` | — |
| 3 | ตรวจมี API Key + Domain name | — |
| 4 | เรียก `try_refresh_zone()` | = กด Save Changes |
| 5 | Cloudflare API → fetch Zone ID | = zone lookup อัตโนมัติ |
| 6 | Verify `cdn-cloudflare_zone` มีค่า | = ผ่าน / ไม่ผ่าน |

---

## ความต้องการ

| รายการ | เวอร์ชัน |
|--------|---------|
| OS | CentOS / CloudLinux / AlmaLinux (cPanel/WHM) |
| WP-CLI | ≥ 2.x |
| LiteSpeed Cache Plugin | ≥ 2.1 |
| Bash | ≥ 4.0 |
| grep | รองรับ `-P` (PCRE) |

---

## ตั้งค่า

แก้ได้ที่บรรทัดบนสุดของ script:

```bash
DELAY_SECONDS=1      # หน่วง (วินาที) หลัง save แต่ละเว็บ (ป้องกัน CF rate limit)
WP_TIMEOUT=60        # timeout ต่อเว็บ (วินาที)
RAM_PER_JOB_MB=150   # RAM ประมาณต่อ parallel job
MAX_JOBS_HARD=20     # จำนวน parallel jobs สูงสุด
```

---

## ค้นหาเว็บอัตโนมัติ 2 แหล่ง

```
แหล่งที่ 1 — WHM
  /etc/trueuserdomains → getent passwd → home dir ทุก cPanel user

แหล่งที่ 2 — Scan โดยตรง
  /home, /home2, /home3, /home4, /home5, /usr/home
  รองรับทั้ง:
    /home/USER/DOMAIN/wp-config.php
    /home/USER/public_html/wp-config.php
```

เว็บซ้ำระหว่างสองแหล่งถูกกรองออกอัตโนมัติ

---

## Skip อัตโนมัติ (ไม่แตะ DB)

| สถานการณ์ | log |
|----------|-----|
| `litespeed-cache` ไม่ active | `SKIP (plugin ไม่ active)` |
| Cloudflare ปิดอยู่ใน plugin | `SKIP (Cloudflare ปิดอยู่)` |
| ไม่มี API Key หรือ Domain | `SKIP (ไม่มี API Key/Domain)` |

---

## Log Files

| ไฟล์ | เนื้อหา |
|------|---------|
| `/var/log/lscwp-cf-save.log` | log รวมทุกเว็บ (real-time) |
| `/var/log/lscwp-cf-save-pass.log` | ✅ เว็บที่ zone กลับมา |
| `/var/log/lscwp-cf-save-fail.log` | ❌ เว็บที่ zone ว่าง (credentials ผิด / CF ไม่ตอบ) |
| `/var/log/lscwp-cf-save-skip.log` | ⏭ เว็บที่ข้ามพร้อมเหตุผล |

### ตัวอย่าง output

```
[2025-03-05 10:00:01] ✅ PASS: armadaso/123x7.net | domain=123x7.net | zone=2f973cea...
[2025-03-05 10:00:02] ❌ FAIL: armadaso2/bad.com  | zone=(empty) | domain=bad.com
[2025-03-05 10:00:03] ⏭  SKIP: armadaso3/wp.com   | cdn-cloudflare=OFF
```

### ดู log real-time ขณะรัน

```bash
tail -f /var/log/lscwp-cf-save.log
```

---

## คำสั่งตรวจสอบ Log

### ดู log รวมทั้งหมด
```bash
cat /var/log/lscwp-cf-save.log
```

### ดูเฉพาะเว็บที่ ✅ Pass
```bash
cat /var/log/lscwp-cf-save-pass.log
```

### ดูเฉพาะเว็บที่ ❌ Fail
```bash
cat /var/log/lscwp-cf-save-fail.log
```

### ดูเฉพาะเว็บที่ ⏭ Skip
```bash
cat /var/log/lscwp-cf-save-skip.log
```

### นับจำนวน Pass / Fail / Skip
```bash
echo "✅ Pass  : $(wc -l < /var/log/lscwp-cf-save-pass.log)"
echo "❌ Fail  : $(wc -l < /var/log/lscwp-cf-save-fail.log)"
echo "⏭  Skip  : $(wc -l < /var/log/lscwp-cf-save-skip.log)"
```

### ดู Fail วันนี้เท่านั้น
```bash
grep "$(date '+%Y-%m-%d')" /var/log/lscwp-cf-save-fail.log
```

### ดู Pass วันนี้เท่านั้น
```bash
grep "$(date '+%Y-%m-%d')" /var/log/lscwp-cf-save-pass.log
```

### ค้นหาเว็บที่ต้องการใน log
```bash
grep "domain.com" /var/log/lscwp-cf-save.log
```

### ล้าง log ทั้งหมด (รันใหม่สะอาด)
```bash
> /var/log/lscwp-cf-save.log
> /var/log/lscwp-cf-save-pass.log
> /var/log/lscwp-cf-save-fail.log
> /var/log/lscwp-cf-save-skip.log
```

---

## Performance

- **Parallel jobs** — คำนวณอัตโนมัติจาก CPU cores + RAM ที่เหลืออยู่
- **1 WP bootstrap ต่อเว็บ** — check + save + verify ใน `wp eval` เดียว
- **ไม่ใช้ python3** — parse ด้วย `grep -P` ล้วน
- **sleep เฉพาะเว็บที่ save จริง** — เว็บ skip ไม่เสียเวลา

---

## ไฟล์ที่เกี่ยวข้องใน repo

| ไฟล์ | คำอธิบาย |
|------|---------|
| [`litespeed-save-change-bulk.sh`](litespeed-save-change-bulk.sh) | Bulk Save Changes ทั่วไป |
| [`litespeed-cloudflare-save-change-bulk.sh`](litespeed-cloudflare-save-change-bulk.sh) | Bulk Save Changes เฉพาะ Cloudflare CDN (ไฟล์นี้) |

---

## License

MIT
