# بکاپ سایت اتحادیه روی سرور ویندوز

این ابزار از **فایل‌های واقعی سرور** بکاپ می‌گیرد: سایت `C:\sites\union-app`، داده‌ها و آپلودها، فایل‌های مخفی مثل `.env` و کلید نشست، خروجی `.next` و وابستگی‌ها، تنظیمات و فضای ذخیرهٔ Caddy و گواهی‌ها و کلیدهای HTTPS. کد قدیمی مخزن را جایگزین سایت نمی‌کند.

سرویس `UnionApp` فقط هنگام کپی سایت متوقف و در بلوک `finally` دوباره راه‌اندازی می‌شود. زمان توقف به حجم سایت و سرعت دیسک بستگی دارد. **Caddy متوقف نمی‌شود**؛ تنظیمات و فایل‌های HTTPS قبل و بعد از کپی هش و با نسخهٔ کپی‌شده مقایسه می‌شوند. اگر تغییری رخ دهد، نتیجه ناقص اعلام می‌شود.

## اجرا روی خود سرور

در PowerShell با **Run as Administrator** اجرا کنید:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$scriptUrl = 'https://raw.githubusercontent.com/sinaalk1994-spec/STLP-MYCOMPANY-/main/server-backup/Backup-UnionServer.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $scriptUrl -OutFile 'C:\Backup-UnionServer.ps1' -ErrorAction Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Backup-UnionServer.ps1'
```

خروجی در یک پوشهٔ جدید و تاریخ‌دار زیر **`C:\UnionFullBackups`** ساخته می‌شود؛ هیچ نسخهٔ قبلی حذف نمی‌شود. فقط حساب SYSTEM و گروه Administrators به پوشهٔ هر بکاپ دسترسی دارند. پیش از توقف سایت، وجود منابع و فضای خالی کنترل می‌شود. ابزار از فشرده‌سازی ZIP استفاده نمی‌کند تا فایل‌های مخفی یا فایل‌های بزرگ حذف نشوند.

برای انتخاب دیسک دیگر:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Backup-UnionServer.ps1' -BackupRoot 'D:\UnionFullBackups'
```

برای شناسایی مسیرها بدون ساخت بکاپ و بدون توقف سرویس:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Backup-UnionServer.ps1' -InspectOnly
```

پایان موفق با `BACKUP COMPLETE` و مسیر پوشه نمایش داده می‌شود. برای گزارش نتیجه فقط محتوای **`summary.json`** همان پوشه را ارسال کنید. `INCOMPLETE` به معنی بکاپ نامعتبر برای اتکای کامل است؛ ابتدا خطا را رفع و دوباره اجرا کنید. اگر بازیابی سرویس هم خطا بدهد، پیام `URGENT` نمایش داده می‌شود و باید وضعیت `UnionApp` بررسی شود.

## محتویات

- `files/`: تمام فایل‌های منابع؛ مسیر اصلی هر منبع در `metadata/restore-paths.json` ثبت می‌شود.
- Caddy اجرایی، Caddyfile و importهای فایل، گواهی/کلیدهای ارجاع‌شده و پوشه‌های موجود Caddy در پروفایل حساب‌های ویندوز، با پشتیبانی از مسیرهای XDG و storage نوع `file_system`.
- Node و فایل اجرایی سرویس‌ها مانند NSSM، مشخصات و رجیستری **فقط سرویس‌های سایت و Caddy**، متغیرهای محیطی شناسایی‌شده و مجوزهای فایل‌ها.
- XML وظایف زمان‌بندی با نام Union/Caddy و مشخصات قواعد فایروال با نام Union/Caddy/tehbatri برای مراجعه هنگام بازیابی.
- `SHA256SUMS.csv`: اندازه و SHA-256 فایل‌های بکاپ؛ `RESTORE.txt`: نکات بازیابی؛ `copy.log`: نتیجهٔ کپی.

داده‌های ERP دیگری مثل `C:\STLP` و سایت‌های دیگر خودکار جزو این بکاپ نیستند. اگر سایت به فایل‌هایی خارج از پوشهٔ خودش وابسته است، مسیر آن‌ها باید با `-ExtraPath` تعیین و سرویس نویسندهٔ آن داده‌ها نیز برای یک کپی سازگار بررسی شود. فقط سرویس `UnionApp` توسط ابزار متوقف می‌شود.

## بررسی سلامت نسخهٔ ذخیره‌شده

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$verifyUrl = 'https://raw.githubusercontent.com/sinaalk1994-spec/STLP-MYCOMPANY-/main/server-backup/Verify-UnionBackup.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $verifyUrl -OutFile 'C:\Verify-UnionBackup.ps1' -ErrorAction Stop
$latest = Get-ChildItem -LiteralPath 'C:\UnionFullBackups' -Directory |
    Where-Object Name -Like 'UnionFull-*' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw 'No backup found' }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Verify-UnionBackup.ps1' -BackupPath $latest.FullName
```

باید پیام `VERIFIED` ببینید. بررسی هش سلامت فایل‌های ذخیره‌شده را می‌سنجد؛ موفقیت عملی بازیابی باید روی سرور آزمایشی جداگانه هم بررسی شود.

## بازیابی و محدوده

ابتدا `RESTORE.txt` و `metadata/restore-paths.json` را بخوانید. پس از تأیید هش، سرویس مقصد را متوقف کنید، کل پوشهٔ سایت را به مسیر ثبت‌شده برگردانید، Caddy و فضای داده و کلیدهایش را با دسترسی محدود بازیابی کنید و با نسخهٔ ثبت‌شدهٔ Node/NSSM سرویس‌های مربوط را بازسازی کنید. رجیستری و XMLها مرجع هستند؛ روی سرور دیگر آن‌ها را بدون بررسی وارد نکنید. مجوزهای ذخیره‌شده با SIDهای ماشین/حساب قبلی باید پیش از `icacls /restore` بررسی شوند.

این بسته **ایمیج کامل ویندوز نیست**. تنظیمات پنل هاست، DNS/Cloudflare و دسترسی حساب‌ها، رمز حساب‌های سفارشی سرویس ویندوز و رمز وظایف Task Scheduler از رجیستری/XML قابل بازیابی نیستند. برای آن‌ها نسخهٔ جداگانه لازم است. سرویس‌ها و برنامه‌های نامرتبط تغییر نمی‌کنند.

ساختار شناخته‌شدهٔ این سایت داده‌های فایل/JSON دارد. ابزار در صورت یافتن متغیرهای رایج دیتابیس خارجی یا SQLite، storage خارجی Caddy، Caddy config نوع JSON یا junction/symlink متوقف می‌شود تا منبع داده جداگانه بررسی شود. برای دیتابیس خارجی باید dump سازگار مخصوص همان موتور اضافه شود. شناسایی خودکار همهٔ مسیرهای ساخته‌شده در کد یا تمام انواع اتصال دیتابیس ممکن نیست؛ تنظیمات سفارشی را باید بررسی کرد. متغیرهای NSSM، متغیرهای ماشین که با `process.env.NAME` در پوشه‌های متداول کد ارجاع شده‌اند و متغیرهای مورد استفادهٔ Caddy ثبت می‌شوند؛ نام‌های محاسبه‌شده و تنظیمات اختصاصی پروفایل کاربر سرویس نیاز به بررسی دارند.

پس از بازیابی آزمایشی، ورود مدیر، تعداد و محتوای داده‌ها، آپلود/دانلود فایل، HTTPS و شروع پس از ریبوت را کنترل کنید.

**بکاپ شامل اطلاعات اعضا، رمزها و کلید خصوصی HTTPS است. آن را در مخزن عمومی گیت‌هاب آپلود نکنید.** پس از اتمام، یک کپی خصوصی روی دستگاه یا فضای دیگری خارج از سرور هم نگه دارید؛ نسخهٔ روی همان دیسک در برابر خرابی خود دیسک کافی نیست.

## آزمون ابزارها

آزمون‌های مسیر، کپی فایل مخفی، تشخیص لینک، تشخیص تغییر گواهی، حالت‌های خطای توقف/کپی/شروع سرویس و تأیید هش با فایل‌های موقت اجرا می‌شوند. عملیات سرویس در آزمون‌ها شبیه‌سازی شده است؛ هیچ سرویس واقعی متوقف نمی‌شود.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-BackupTools.ps1
```

این آزمون‌ها روی PowerShell 5.1 و 7 اجرا شده‌اند؛ بکاپ و بازیابی واقعی سرور باید پس از اجرای مالک سرور بررسی شود.
