# آیکون آیفون و افزودن تهران‌ولت به Home Screen

این فایل‌ها از همان تصویر فارسی اپ اندروید، با همان زمینهٔ شیری و حاشیه تهیه شده‌اند. فایل آیفون PNG بدون شفافیت و ۱۸۰×۱۸۰ است. این پوشه **بستهٔ نصب روی سایت اصلی** است؛ قرارگرفتن آن در گیت‌هاب به‌تنهایی سایت `tehbatri.ir` را تغییر نمی‌دهد.

## نصب روی سایت اصلی

۱. محتویات `public/` را در مسیر فایل‌های عمومی سایت اصلی قرار دهید، به‌گونه‌ای که این URLها بدون ورود قابل دریافت باشند:

- `https://tehbatri.ir/apple-touch-icon.png`
- `https://tehbatri.ir/icons/tehran-volt-apple-v1.png`
- `https://tehbatri.ir/tehran-volt.webmanifest`
- دو فایل `tehran-volt-192.png` و `tehran-volt-512.png` در `/icons/`.

۲. تگ‌های `head-snippet.html` را با تنظیمات `<head>` سایت اصلی ادغام کنید. برای یک تنظیم، چند تگ متناقض نسازید. تگ آیکون و نام باید هم در `/admin` و هم در صفحهٔ ورود آن موجود باشند. اگر فقط لوگو لازم است، فایل `apple-touch-icon.png` در ریشه و تگ `apple-touch-icon` کافی‌اند؛ manifest و متاتگ‌ها نام و حالت مستقل اپ را هم تعیین می‌کنند.

۳. سایت را با روش معمول هاست منتشر یا restart کنید. لازم نیست کد سایت اصلی را با پروژهٔ محلی متفاوت جایگزین کنید. اگر Nginx یا proxy همهٔ مسیرها را به برنامه می‌فرستد، صرف کپی در ریشهٔ هاست کافی نیست؛ از پوشهٔ عمومی‌ای استفاده کنید که برنامه واقعاً سرو می‌کند.

## اگر سایت اصلی Next.js App Router است

فایل‌های این بستهٔ `public/` را به `public/` **پروژهٔ اصلی** منتقل و تنظیمات زیر را با `metadata` فعلی در layout اصلی یا layout مدیریت ادغام کنید:

```tsx
import type { Metadata } from "next";

// Add these fields to the existing metadata object; preserve the other settings.
const homeScreenMetadata: Metadata = {
  manifest: "/tehran-volt.webmanifest",
  icons: {
    apple: [{ url: "/icons/tehran-volt-apple-v1.png", sizes: "180x180", type: "image/png" }],
  },
  appleWebApp: {
    capable: true,
    title: "تهران‌ولت",
    statusBarStyle: "default",
  },
};
```

این ثابت نمونه را با export فعلی ادغام کنید؛ آن را به‌عنوان export دومِ metadata یا جایگزین کل layout کپی نکنید. اگر پروژه قبلاً `app/apple-icon.png` یا نسخهٔ کدنویسی‌شدهٔ آن دارد، همان فایل را هم با آیکون جدید هماهنگ کنید؛ metadata فایل‌ها در Next.js اولویت دارد. سپس build و انتشار معمول پروژهٔ اصلی انجام شود.

## افزودن از آیفون، پس از انتشار

۱. اگر میان‌بر قدیمی دارید، آن را از صفحهٔ اصلی بردارید تا آیکون جدید دوباره دریافت شود.
۲. در Safari به `https://tehbatri.ir/admin` بروید.
۳. Share / اشتراک‌گذاری ← Add to Home Screen / افزودن به صفحهٔ اصلی را انتخاب کنید.
۴. نام «تهران‌ولت» و تصویر جدید را در پیش‌نمایش بررسی و Add را بزنید. اگر Open as Web App نمایش داده شد، برای بازشدن به‌صورت اپ آن را فعال کنید.

این میان‌بر وب است و ورود و نشست آن باید روی آیفون تست شود. حفظ ورود تابع سیاست کوکی و انقضای نشست خود سایت است. هیچ Service Worker یا کش آفلاین برای اطلاعات مدیریتی در این بسته اضافه نشده است.

## بررسی بعد از انتشار

- URL تصویر با پاسخ موفق و نوع `image/png` و بدون redirect به login باز شود.
- `<head>` صفحهٔ مدیریت و ورود، آدرس `tehran-volt-apple-v1.png` را داشته باشد.
- manifest معتبر و با نام و start_url صحیح دریافت شود.
- در پیش‌نمایش Add to Home Screen و پس از نصب روی آیفون، تصویر، نام و برش گوشه‌ها بررسی شود.

منابع: [تنظیم آیکون وب در مستندات اپل](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/ConfiguringWebApplications/ConfiguringWebApplications.html) و [راهنمای آیفون اپل](https://support.apple.com/guide/iphone/bookmark-a-website-iph42ab2f3a7/ios).
