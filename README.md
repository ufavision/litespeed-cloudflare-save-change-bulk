# litespeed-cloudflare-save-change-bulk.sh

> Bulk **"Save Changes"** — LiteSpeed Cache › CDN › Tab Cloudflare › Cloudflare Setting  
> รันครั้งเดียว ครอบคลุมทุกเว็บใน cPanel/WHM server

---

## วิธีรัน

```bash
bash <(curl -s https://raw.githubusercontent.com/ufavision/litespeed-cloudflare-zone-save-change-bulk/main/litespeed-cloudflare-zone-save-change-bulk.sh)
```
---

## ทำอะไร

เทียบเท่ากับการกดปุ่ม **Save Changes** บนหน้า Admin UI ของทุกเว็บ:

```
LiteSpeed Cache › CDN › Tab Cloudflare › Cloudflare Setting › Save Changes
```

### Core method (ยืนยันจากการทดสอบจริง)

```php
// ยิง Cloudflare API โดยตรง + update_option() บันทึกลง DB ทันที
// (try_refresh_zone() ไม่ commit ลง DB ใน CLI context เพราะรอ WP shutdown hook)
$zone_id = cloudflare_api_fetch_zone($name);
update_option("litespeed.conf.cdn-cloudflare_zone", $zone_id);
```

### ขั้นตอนต่อเว็บ

| # | สิ่งที่ทำ |
|---|----------|
| 1 | ตรวจ `litespeed-cache` plugin active |
| 2 | ตรวจ `cdn-cloudflare = 1` (เปิดอยู่) |
| 3 | ตรวจ มี API Key + Domain name |
| 4 | ตรวจ domain ใน plugin ตรงกับ folder ไหม → ถ้าไม่ตรง แก้อัตโนมัติ |
| 5 | ตรวจ มี Zone ID อยู่แล้วไหม → ถ้ามี ข้ามไป |
| 6 | ยิง Cloudflare API fetch Zone ID (retry สูงสุด 3 ครั้ง) |
| 7 | บันทึก Zone ID ลง DB โดยตรง |
| 8 | Verify + log ผล |

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
MAX_JOBS=5       # parallel jobs (แนะนำ 5 — ปลอดภัยสำหรับ 2 CF account)
WP_TIMEOUT=30    # timeout ต่อเว็บ (วินาที)
MAX_RETRY=3      # retry สูงสุดต่อเว็บ (กรณี CF ไม่ตอบ)
RETRY_DELAY=5    # รอ (วินาที) ก่อน retry
```

---

## สรุปผลรวม (แสดงหลังรันเสร็จ)

```
======================================
 สรุปผลรวม
 รวมทั้งหมด      : 1197 เว็บ
 ✅ Pass          :  800 เว็บ
 ✔️  Has Zone     :  100 เว็บ
 ❌ Fail          :   10 เว็บ
 🌐 Not in CF     :  200 เว็บ
 ⚙️  Auto-fixed   :   50 เว็บ
 🔴 CF Off        :   20 เว็บ
 ⏭  Skip          :   17 เว็บ
 เวลาที่ใช้       :    6 นาที 23 วินาที
======================================
```

### อธิบายแต่ละสถานะ

| สถานะ | ความหมาย |
|-------|---------|
| ✅ **Pass** | ยิง CF API สำเร็จ ได้ Zone ID กลับมา บันทึกลง DB แล้ว |
| ✔️ **Has Zone** | มี Zone ID อยู่แล้วใน DB ข้ามไปไม่ยิง CF API (ประหยัด rate limit) |
| ❌ **Fail** | ยิง CF API แล้ว error เช่น timeout, HTTP error, CF ไม่ตอบ retry ครบ 3 ครั้งแล้วยังไม่ได้ |
| 🌐 **Not in CF** | CF API ตอบกลับปกติ แต่ไม่พบ domain นี้ใน account (domain ยังไม่ได้ add ใน Cloudflare) |
| ⚙️ **Auto-fixed** | domain ใน plugin ไม่ตรงกับ folder → script แก้ domain อัตโนมัติแล้วยิง CF API ใหม่ |
| 🔴 **CF Off** | Cloudflare ถูกปิดอยู่ใน LiteSpeed Cache plugin (cdn-cloudflare=0) |
| ⏭️ **Skip** | plugin ไม่ active หรือไม่มี API Key/Domain → เว็บใหม่ยังไม่ได้ขึ้น หรือยังไม่ได้ตั้งค่า |

---

## Log Files

| ไฟล์ | สถานะ | เนื้อหา |
|------|-------|---------|
| `/var/log/lscwp-cf-save.log` | ทั้งหมด | log รวมทุก event real-time |
| `/var/log/lscwp-cf-save-pass.log` | ✅ Pass | เว็บที่ได้ Zone ID สำเร็จ |
| `/var/log/lscwp-cf-save-haszone.log` | ✔️ Has Zone | เว็บที่มี Zone อยู่แล้ว |
| `/var/log/lscwp-cf-save-fail.log` | ❌ Fail | เว็บที่ CF API error / timeout |
| `/var/log/lscwp-cf-save-notcf.log` | 🌐 Not in CF | เว็บที่ domain ไม่อยู่ใน CF account |
| `/var/log/lscwp-cf-save-cfoff.log` | 🔴 CF Off | เว็บที่ปิด Cloudflare ใน plugin |
| `/var/log/lscwp-cf-save-skip.log` | ⏭️ Skip | เว็บที่ข้าม (plugin ปิด / ไม่มี key) |

> **หมายเหตุ:** log ทุกไฟล์จะถูก **clear อัตโนมัติทุกครั้งที่รัน** — แสดงเฉพาะผลของ run ล่าสุดเท่านั้น

---

## คำสั่งดู Log

### ดู real-time ขณะรัน
```bash
tail -f /var/log/lscwp-cf-save.log
```

### ดู log รวมทั้งหมด
```bash
cat /var/log/lscwp-cf-save.log
```

### ดูเฉพาะ ✅ Pass
```bash
cat /var/log/lscwp-cf-save-pass.log
```

### ดูเฉพาะ ✔️ Has Zone (มี zone อยู่แล้ว)
```bash
cat /var/log/lscwp-cf-save-haszone.log
```

### ดูเฉพาะ ❌ Fail
```bash
cat /var/log/lscwp-cf-save-fail.log
```

### ดูเฉพาะ 🌐 Not in CF
```bash
cat /var/log/lscwp-cf-save-notcf.log
```

### ดูเฉพาะ 🔴 CF Off
```bash
cat /var/log/lscwp-cf-save-cfoff.log
```

### ดูเฉพาะ ⏭️ Skip
```bash
cat /var/log/lscwp-cf-save-skip.log
```

### นับจำนวนแต่ละประเภท
```bash
echo "✅ Pass     : $(wc -l < /var/log/lscwp-cf-save-pass.log)"
echo "✔️  Has Zone : $(wc -l < /var/log/lscwp-cf-save-haszone.log)"
echo "❌ Fail     : $(wc -l < /var/log/lscwp-cf-save-fail.log)"
echo "🌐 Not in CF: $(wc -l < /var/log/lscwp-cf-save-notcf.log)"
echo "🔴 CF Off   : $(wc -l < /var/log/lscwp-cf-save-cfoff.log)"
echo "⏭  Skip     : $(wc -l < /var/log/lscwp-cf-save-skip.log)"
```

### ดูเฉพาะเว็บที่ถูก Auto-fixed
```bash
grep "domain ถูกแก้อัตโนมัติ" /var/log/lscwp-cf-save-pass.log /var/log/lscwp-cf-save-notcf.log /var/log/lscwp-cf-save-fail.log
```

### ค้นหาเว็บที่ต้องการ
```bash
grep "domain.com" /var/log/lscwp-cf-save.log
```

### ดูเฉพาะวันนี้
```bash
grep "$(date '+%Y-%m-%d')" /var/log/lscwp-cf-save.log
```

---

## Performance

- **Parallel jobs** — รัน 5 jobs พร้อมกัน (ปลอดภัยสำหรับ 2 CF account)
- **1 WP bootstrap ต่อเว็บ** — check + save + verify ใน `wp eval` เดียว
- **ไม่ยิง CF API ซ้ำ** — เว็บที่มี Zone อยู่แล้วจะถูกข้ามทันที
- **Auto-fix domain** — domain ผิดจะถูกแก้อัตโนมัติจาก folder name
- **Retry 3 ครั้ง** — รอ 5 วินาทีระหว่าง retry กรณี CF ไม่ตอบ
- **ไม่ใช้ python3** — parse ด้วย `grep -P` ล้วน

### ประมาณการเวลา
```
1,197 เว็บ ÷ 5 jobs × 1.5 วินาที = ~6 นาที
```

---

## ไฟล์ที่เกี่ยวข้องใน repo

| ไฟล์ | คำอธิบาย |
|------|---------|
| [`litespeed-save-change-bulk.sh`](litespeed-save-change-bulk.sh) | Bulk Save Changes ทั่วไป |
| [`litespeed-cloudflare-save-change-bulk.sh`](litespeed-cloudflare-save-change-bulk.sh) | Bulk Save Changes เฉพาะ Cloudflare CDN (ไฟล์นี้) |

---

## License

MIT
