package ir.tehbatri.admin;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.print.PrintAttributes;
import android.print.PrintManager;
import android.provider.DocumentsContract;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.SslErrorHandler;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/** A deliberately thin client: authentication, permissions and data stay on the live ERP. */
public final class MainActivity extends Activity {
    private static final int REQUEST_UPLOAD = 40;
    private static final int REQUEST_SAVE = 41;
    private static final long MAX_DOWNLOAD_BYTES = 100L * 1024 * 1024;
    private static final int MAX_BLOB_BYTES = 32 * 1024 * 1024;
    private static final int BLOB_CHUNK_BYTES = 192 * 1024;
    private static final int BACKGROUND = Color.rgb(250, 249, 246);
    private static final int INK = Color.rgb(18, 41, 74);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    // A random JS property is only a bounded data buffer; no Java/native object is exposed.
    private final String blobStore = "__tv_" + UUID.randomUUID().toString().replace("-", "");
    private WebView web;
    private ProgressBar progress;
    private LinearLayout errorPanel;
    private TextView errorMessage;
    private ValueCallback<Uri[]> uploadCallback;
    private Download export;
    private boolean destroyed;
    private boolean rendererGone;
    private boolean pageFailed;
    private String retryUrl = UrlPolicy.HOME;
    private String adminLayoutScript;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        buildInterface();
        configureWebView();
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::navigateBack);
        }
        boolean restored = false;
        if (state != null) {
            Bundle browserState = state.getBundle("browser");
            if (browserState != null) restored = web.restoreState(browserState) != null;
        }
        if (!restored || !UrlPolicy.isInternal(web.getUrl())) web.loadUrl(UrlPolicy.HOME);
    }

    private void buildInterface() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BACKGROUND);
        root.setLayoutDirection(View.LAYOUT_DIRECTION_RTL);

        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((view, insets) -> {
                Insets safe = insets.getInsets(WindowInsets.Type.systemBars()
                        | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom);
                return WindowInsets.CONSUMED;
            });
        } else {
            root.setFitsSystemWindows(true);
            getWindow().setStatusBarColor(BACKGROUND);
            getWindow().setNavigationBarColor(BACKGROUND);
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                    | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }

        LinearLayout toolbar = new LinearLayout(this);
        toolbar.setGravity(Gravity.CENTER_VERTICAL);
        toolbar.setPadding(dp(6), 0, dp(6), 0);
        root.addView(toolbar, new LinearLayout.LayoutParams(-1, dp(52)));
        TextView title = new TextView(this);
        title.setText("تهران‌ولت  |  مدیریت اتحادیه");
        title.setTextSize(15);
        title.setTextColor(INK);
        title.setGravity(Gravity.CENTER_VERTICAL);
        toolbar.addView(title, new LinearLayout.LayoutParams(0, -1, 1));
        Button menu = toolbarButton("⋮", "گزینه‌ها");
        toolbar.addView(menu, new LinearLayout.LayoutParams(dp(48), dp(48)));
        menu.setOnClickListener(v -> showMenu(menu));

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        root.addView(progress, new LinearLayout.LayoutParams(-1, dp(3)));
        FrameLayout content = new FrameLayout(this);
        root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
        web = new WebView(this);
        content.addView(web, new FrameLayout.LayoutParams(-1, -1));

        errorPanel = new LinearLayout(this);
        errorPanel.setOrientation(LinearLayout.VERTICAL);
        errorPanel.setGravity(Gravity.CENTER);
        errorPanel.setPadding(dp(24), dp(24), dp(24), dp(24));
        errorPanel.setBackgroundColor(BACKGROUND);
        errorMessage = new TextView(this);
        errorMessage.setTextColor(INK);
        errorMessage.setTextSize(17);
        errorMessage.setGravity(Gravity.CENTER);
        errorPanel.addView(errorMessage, new LinearLayout.LayoutParams(-1, -2));
        Button retry = toolbarButton("تلاش دوباره", "تلاش دوباره برای اتصال");
        LinearLayout.LayoutParams retryLayout = new LinearLayout.LayoutParams(-2, dp(54));
        retryLayout.topMargin = dp(18);
        errorPanel.addView(retry, retryLayout);
        retry.setOnClickListener(v -> {
            if (rendererGone) recreate();
            else web.loadUrl(UrlPolicy.isInternal(retryUrl) ? retryUrl : UrlPolicy.HOME);
        });
        content.addView(errorPanel, new FrameLayout.LayoutParams(-1, -1));
        errorPanel.setVisibility(View.GONE);
        setContentView(root);
        if (Build.VERSION.SDK_INT >= 30) root.post(() -> {
            android.view.WindowInsetsController controller = root.getWindowInsetsController();
            if (controller != null) controller.setSystemBarsAppearance(
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                            | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                            | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
        });
        root.requestApplyInsets();
    }

    private Button toolbarButton(String text, String accessibility) {
        Button button = new Button(this);
        button.setText(text);
        button.setContentDescription(accessibility);
        button.setTextColor(INK);
        button.setTextSize(15);
        button.setAllCaps(false);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        button.setPadding(dp(10), 0, dp(10), 0);
        return button;
    }

    private void configureWebView() {
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true); // Required by the existing Next.js ERP.
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSafeBrowsingEnabled(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(true);
        settings.setSupportZoom(true);
        settings.setBuiltInZoomControls(true);
        settings.setDisplayZoomControls(false);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setMediaPlaybackRequiresUserGesture(true);
        web.setBackgroundColor(Color.WHITE);
        web.setScrollBarStyle(View.SCROLLBARS_INSIDE_OVERLAY);
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(web, false);
        // Web content debugging remains disabled in release builds and no JS bridge is installed.
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String url = request.getUrl().toString();
                if (!request.isForMainFrame()) return !UrlPolicy.isInternal(url);
                return routeNavigation(url, request.hasGesture());
            }

            @Override public void onPageStarted(WebView view, String url, android.graphics.Bitmap icon) {
                if (!UrlPolicy.isInternal(url)) {
                    view.stopLoading();
                    showError("این نشانی داخل پنل اتحادیه نیست.");
                    return;
                }
                retryUrl = url;
                pageFailed = false;
                errorPanel.setVisibility(View.GONE);
                progress.setVisibility(View.VISIBLE);
            }

            @Override public void onPageFinished(WebView view, String url) {
                CookieManager.getInstance().flush();
                if (!pageFailed && UrlPolicy.isInternal(url)) {
                    installBlobBuffer();
                    installAdminLayoutFix();
                }
            }

            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) showError("اتصال به پنل برقرار نشد. اینترنت را بررسی و دوباره تلاش کنید.");
            }

            @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame() && response.getStatusCode() >= 500)
                    showError("سرور پنل موقتاً پاسخ نمی‌دهد. کمی بعد دوباره تلاش کنید.");
            }

            @Override public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                handler.cancel();
                showError("اتصال امن سایت تأیید نشد. تاریخ گوشی و گواهی سایت را بررسی کنید.");
            }

            @Override public boolean onRenderProcessGone(WebView view, android.webkit.RenderProcessGoneDetail detail) {
                rendererGone = true;
                if (export != null) cancelExport(export);
                completeUpload(null);
                if (view.getParent() instanceof android.view.ViewGroup)
                    ((android.view.ViewGroup) view.getParent()).removeView(view);
                view.destroy();
                showError("نمایش پنل متوقف شد. برای باز کردن دوباره تلاش کنید؛ تغییرات ذخیره‌نشده ممکن است از دست رفته باشند.");
                return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onProgressChanged(WebView view, int value) {
                progress.setProgress(value);
                if (value == 100) progress.setVisibility(View.GONE);
            }

            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (!UrlPolicy.isInternal(view.getUrl())) { callback.onReceiveValue(null); return true; }
                if (uploadCallback != null) uploadCallback.onReceiveValue(null);
                uploadCallback = callback;
                Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                pick.addCategory(Intent.CATEGORY_OPENABLE);
                pick.setType("*/*");
                LinkedHashSet<String> accepted = new LinkedHashSet<>();
                for (String type : params.getAcceptTypes()) {
                    if (type != null && type.trim().matches("[a-zA-Z0-9.+_-]+/[a-zA-Z0-9.+_*-]+")) accepted.add(type.trim());
                }
                if (!accepted.isEmpty()) pick.putExtra(Intent.EXTRA_MIME_TYPES, accepted.toArray(new String[0]));
                pick.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
                try { startActivityForResult(pick, REQUEST_UPLOAD); }
                catch (ActivityNotFoundException e) { completeUpload(null); toast("انتخاب‌گر فایل روی گوشی در دسترس نیست."); }
                return true;
            }

            @Override public void onPermissionRequest(PermissionRequest request) { request.deny(); }

            @Override public boolean onCreateWindow(WebView view, boolean dialog, boolean userGesture, android.os.Message message) {
                if (!userGesture || !UrlPolicy.isInternal(view.getUrl())) return false;
                // A transient target only routes the destination; no Java/native bridge is installed.
                WebView target = new WebView(MainActivity.this);
                target.getSettings().setJavaScriptEnabled(false);
                target.getSettings().setAllowFileAccess(false);
                target.getSettings().setAllowContentAccess(false);
                CookieManager.getInstance().setAcceptThirdPartyCookies(target, false);
                target.setWebViewClient(new WebViewClient() {
                    private boolean handled;
                    private void open(String url) {
                        if (handled || "about:blank".equals(url)) return;
                        handled = true;
                        target.stopLoading();
                        if (UrlPolicy.isInternal(url)) web.loadUrl(url);
                        else routeNavigation(url, true);
                        main.post(target::destroy);
                    }
                    @Override public boolean shouldOverrideUrlLoading(WebView popup, WebResourceRequest request) { open(request.getUrl().toString()); return true; }
                    @Override public void onPageStarted(WebView popup, String url, android.graphics.Bitmap icon) { open(url); }
                    @Override public boolean onRenderProcessGone(WebView popup, android.webkit.RenderProcessGoneDetail detail) {
                        handled = true;
                        popup.destroy();
                        return true;
                    }
                });
                ((WebView.WebViewTransport) message.obj).setWebView(target);
                message.sendToTarget();
                main.postDelayed(() -> { try { target.destroy(); } catch (Exception ignored) { } }, 15000);
                return true;
            }
        });
        web.setDownloadListener((url, userAgent, disposition, mime, size) -> requestDownload(url, disposition, mime, size));
    }

    private boolean routeNavigation(String url, boolean userGesture) {
        if (UrlPolicy.isInternal(url)) return false;
        if (UrlPolicy.isInternalBlob(url) && UrlPolicy.isInternal(web.getUrl())) {
            requestDownload(url, null, null, -1);
        } else if (userGesture && UrlPolicy.isExternalAllowed(url)) {
            Uri uri = Uri.parse(url);
            String destination = uri.getHost() == null ? uri.getScheme() : uri.getHost();
            new AlertDialog.Builder(this).setTitle("باز کردن خارج از برنامه")
                    .setMessage(destination)
                    .setPositiveButton("باز کردن", (dialog, which) -> openExternal(uri))
                    .setNegativeButton("انصراف", null).show();
        } else toast("این پیوند داخل برنامه باز نمی‌شود.");
        return true;
    }

    private void openExternal(Uri uri) {
        if (!UrlPolicy.isExternalAllowed(uri.toString())) return;
        Intent intent = new Intent(Intent.ACTION_VIEW, uri);
        intent.addCategory(Intent.CATEGORY_BROWSABLE);
        try { startActivity(intent); }
        catch (ActivityNotFoundException | SecurityException e) { toast("برنامه‌ای برای باز کردن این پیوند پیدا نشد."); }
    }

    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(0, 1, 0, "بازگشت");
        menu.getMenu().add(0, 2, 1, "صفحه اصلی پنل");
        menu.getMenu().add(0, 3, 2, "بازخوانی صفحه");
        menu.getMenu().add(0, 4, 3, "چاپ / ذخیره PDF این صفحه");
        menu.setOnMenuItemClickListener(item -> {
            if (rendererGone && item.getItemId() != 1) { recreate(); return true; }
            switch (item.getItemId()) {
                case 1: navigateBack(); break;
                case 2: web.loadUrl(UrlPolicy.HOME); break;
                case 3: new AlertDialog.Builder(this).setMessage("صفحه بازخوانی شود؟ تغییرات ذخیره‌نشده ممکن است از دست بروند.")
                        .setPositiveButton("بازخوانی", (dialog, which) -> web.reload()).setNegativeButton("انصراف", null).show(); break;
                case 4: printPage(); break;
                default: return false;
            }
            return true;
        });
        menu.show();
    }

    private void printPage() {
        if (rendererGone || !UrlPolicy.isInternal(web.getUrl()) || pageFailed) return;
        PrintManager printer = (PrintManager) getSystemService(PRINT_SERVICE);
        if (printer == null) { toast("خدمات چاپ روی گوشی در دسترس نیست."); return; }
        try {
            printer.print("تهران‌ولت", web.createPrintDocumentAdapter("TehranVolt"), new PrintAttributes.Builder().build());
        } catch (RuntimeException e) { toast("چاپ این صفحه در دسترس نیست."); }
    }

    private void requestDownload(String url, String disposition, String mime, long size) {
        if (destroyed || rendererGone || !UrlPolicy.isInternal(web.getUrl())) return;
        if (export != null) { toast("ابتدا ذخیره فایل قبلی را تمام کنید."); return; }
        if (!UrlPolicy.isInternal(url) && !UrlPolicy.isInternalBlob(url)) {
            routeNavigation(url, true); return;
        }
        if (size > MAX_DOWNLOAD_BYTES) { toast("حداکثر حجم دریافت فایل ۱۰۰ مگابایت است."); return; }
        Download item = new Download();
        item.url = url;
        item.mime = cleanMime(mime);
        item.name = UrlPolicy.safeFileName(URLUtil.guessFileName(url, disposition, item.mime));
        item.blob = UrlPolicy.isInternalBlob(url);
        item.id = UUID.randomUUID().toString().replace("-", "");
        export = item;
        if (item.blob) prepareBlob(item); else chooseDestination(item);
    }

    private void chooseDestination(Download item) {
        if (!isCurrent(item)) return;
        Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        save.addCategory(Intent.CATEGORY_OPENABLE);
        save.setType(item.mime);
        save.putExtra(Intent.EXTRA_TITLE, item.name);
        try { startActivityForResult(save, REQUEST_SAVE); }
        catch (ActivityNotFoundException e) { failExport(item, "انتخاب محل ذخیره روی گوشی در دسترس نیست."); }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == REQUEST_UPLOAD) {
            if (result != RESULT_OK || data == null) { completeUpload(null); return; }
            List<Uri> files = new ArrayList<>();
            ClipData clip = data.getClipData();
            if (clip != null) {
                for (int i = 0; i < Math.min(clip.getItemCount(), 50); i++) addPickedUri(files, clip.getItemAt(i).getUri());
            } else addPickedUri(files, data.getData());
            completeUpload(files.isEmpty() ? null : files.toArray(new Uri[0]));
        } else if (request == REQUEST_SAVE && export != null) {
            Download item = export;
            Uri uri = data == null ? null : data.getData();
            if (result != RESULT_OK || uri == null || !"content".equals(uri.getScheme())) { cancelExport(item); return; }
            item.destination = uri;
            toast("در حال ذخیره فایل…");
            if (item.blob) {
                io.execute(() -> {
                    try {
                        item.stream = getContentResolver().openOutputStream(uri, "wt");
                        if (item.stream == null) throw new IOException("No destination stream");
                        main.post(() -> readBlobChunk(item, 0));
                    } catch (Exception e) { main.post(() -> failExport(item, "فایل ذخیره نشد. محل ذخیره را بررسی کنید.")); }
                });
            } else io.execute(() -> downloadHttp(item));
        }
    }

    private void addPickedUri(List<Uri> files, Uri uri) {
        // Do not pass file:// URIs or arbitrary values returned by a third party picker to the site.
        if (uri != null && "content".equals(uri.getScheme())) files.add(uri);
    }

    private void completeUpload(Uri[] files) {
        ValueCallback<Uri[]> callback = uploadCallback;
        uploadCallback = null;
        if (callback != null) callback.onReceiveValue(files);
    }

    private void downloadHttp(Download item) {
        HttpURLConnection connection = null;
        try {
            URL address = new URL(item.url);
            for (int redirects = 0; redirects <= 5; redirects++) {
                if (item.cancelled || !UrlPolicy.isInternal(address.toString())) throw new IOException("Unsafe destination");
                connection = (HttpURLConnection) address.openConnection();
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(20000);
                connection.setReadTimeout(30000);
                connection.setRequestProperty("User-Agent", item.userAgent);
                connection.setRequestProperty("Accept-Encoding", "identity");
                String cookie = CookieManager.getInstance().getCookie(address.toString());
                if (cookie != null && !cookie.isEmpty()) connection.setRequestProperty("Cookie", cookie);
                int code = connection.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String location = connection.getHeaderField("Location");
                    if (location == null || redirects == 5) throw new IOException("Invalid redirect");
                    URL next = new URL(address, location);
                    if (!UrlPolicy.isInternal(next.toString())) throw new IOException("Cross-origin redirect blocked");
                    connection.disconnect();
                    connection = null;
                    address = next;
                    continue;
                }
                if (code < 200 || code >= 300) throw new IOException("Download response " + code);
                String responseMime = cleanMime(connection.getContentType());
                // An expired session often redirects a PDF request to a successful HTML login page.
                if (responseMime.equals("text/html") || responseMime.equals("application/xhtml+xml"))
                    throw new IOException("Login page returned instead of a file");
                if (connection.getContentLengthLong() > MAX_DOWNLOAD_BYTES) throw new IOException("File too large");
                try (InputStream source = connection.getInputStream();
                     OutputStream destination = getContentResolver().openOutputStream(item.destination, "wt")) {
                    if (destination == null) throw new IOException("No destination stream");
                    byte[] buffer = new byte[32768];
                    long total = 0;
                    int count;
                    while ((count = source.read(buffer)) != -1) {
                        if (item.cancelled || (total += count) > MAX_DOWNLOAD_BYTES) throw new IOException("Transfer cancelled or too large");
                        destination.write(buffer, 0, count);
                    }
                    destination.flush();
                }
                main.post(() -> finishExport(item));
                return;
            }
        } catch (Exception e) {
            main.post(() -> failExport(item, "دریافت فایل انجام نشد. اتصال و ورود به پنل را بررسی کنید (حداکثر ۱۰۰ مگابایت)."));
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private void installAdminLayoutFix() {
        if (destroyed || rendererGone || !UrlPolicy.isInternal(web.getUrl())) return;
        if (adminLayoutScript == null) {
            try (InputStream source = getAssets().open("admin-mobile-fix.js");
                 ByteArrayOutputStream buffer = new ByteArrayOutputStream()) {
                byte[] chunk = new byte[4096];
                int count;
                while ((count = source.read(chunk)) != -1) buffer.write(chunk, 0, count);
                adminLayoutScript = new String(buffer.toByteArray(), StandardCharsets.UTF_8);
            } catch (IOException e) {
                toast("اصلاح نمایش موبایل بارگذاری نشد. برنامه را دوباره باز کنید.");
                return;
            }
        }
        web.evaluateJavascript(adminLayoutScript, null);
    }

    /** Keeps only recently created blobs, bounded in size; preserves exports that immediately revoke their URL. */
    private void installBlobBuffer() {
        String key = JSONObject.quote(blobStore);
        String script = "(()=>{if(location.origin!==" + JSONObject.quote(UrlPolicy.ORIGIN) + ")return;"
                + "const k=" + key + ";if(window[k])return;"
                + "const s={items:{},names:{},tasks:{},bytes:0};window[k]=s;"
                + "const create=URL.createObjectURL.bind(URL);URL.createObjectURL=function(b){const u=create(b);"
                + "if(b instanceof Blob&&b.size<=" + MAX_BLOB_BYTES + "){"
                + "for(const old of Object.keys(s.items)){if(s.bytes+b.size<=" + MAX_BLOB_BYTES + "&&Object.keys(s.items).length<8)break;s.bytes-=s.items[old].size;delete s.items[old];delete s.names[old];}"
                + "s.items[u]=b;s.bytes+=b.size;setTimeout(()=>{if(s.items[u]){s.bytes-=s.items[u].size;delete s.items[u];delete s.names[u];}},60000);}return u;};"
                + "document.addEventListener('click',e=>{const a=e.target&&e.target.closest?e.target.closest('a'):null;"
                + "if(a&&a.href&&s.items[a.href])s.names[a.href]=a.download||'';},true);})()";
        web.evaluateJavascript(script, null);
    }

    private void prepareBlob(Download item) {
        String script = "(()=>{if(location.origin!==" + JSONObject.quote(UrlPolicy.ORIGIN) + ")return;const s=window["
                + JSONObject.quote(blobStore) + "];if(!s)return;const id=" + JSONObject.quote(item.id)
                + ",url=" + JSONObject.quote(item.url) + ";const t=s.tasks[id]={status:'loading'};"
                + "const ready=b=>{if(b.size>" + MAX_BLOB_BYTES + "){t.status='error';return;}t.blob=b;t.size=b.size;"
                + "t.mime=b.type||'application/octet-stream';t.name=s.names[url]||b.name||'';t.status='ready';};"
                + "if(s.items[url])ready(s.items[url]);else fetch(url).then(r=>r.blob()).then(ready).catch(()=>{t.status='error';});})()";
        installBlobBuffer();
        web.evaluateJavascript(script, result -> pollBlobReady(item, 0));
    }

    private void pollBlobReady(Download item, int attempt) {
        if (!isCurrent(item)) return;
        if (attempt >= 150 || !UrlPolicy.isInternal(web.getUrl())) { failExport(item, "خروجی آماده نشد. دوباره خروجی بگیرید (حداکثر ۳۲ مگابایت)."); return; }
        evaluateObject(blobTaskExpression(item, "({status:t.status,size:t.size,mime:t.mime,name:t.name})"), object -> {
            if (!isCurrent(item)) return;
            String status = object == null ? "error" : object.optString("status");
            if ("ready".equals(status)) {
                item.size = object.optInt("size", -1);
                if (item.size < 0 || item.size > MAX_BLOB_BYTES) { failExport(item, "حداکثر حجم خروجی این صفحه ۳۲ مگابایت است."); return; }
                item.mime = cleanMime(object.optString("mime"));
                String name = object.optString("name");
                item.name = UrlPolicy.safeFileName(name.isEmpty() ? defaultBlobName(item.mime) : name);
                chooseDestination(item);
            } else if ("loading".equals(status)) main.postDelayed(() -> pollBlobReady(item, attempt + 1), 100);
            else failExport(item, "خروجی آماده نشد. دوباره خروجی بگیرید (حداکثر ۳۲ مگابایت).");
        });
    }

    private void readBlobChunk(Download item, int offset) {
        if (!isCurrent(item)) return;
        if (!UrlPolicy.isInternal(web.getUrl())) { failExport(item, "صفحه تغییر کرد؛ دوباره خروجی بگیرید."); return; }
        if (offset >= item.size) {
            io.execute(() -> {
                try { closeBlobStream(item); main.post(() -> finishExport(item)); }
                catch (IOException e) { main.post(() -> failExport(item, "ذخیره فایل کامل نشد.")); }
            });
            return;
        }
        int end = Math.min(item.size, offset + BLOB_CHUNK_BYTES);
        String expression = blobTaskExpression(item,
                "(()=>{t.chunk=null;t.chunkError=false;const r=new FileReader();"
                        + "r.onload=()=>{t.chunk=String(r.result).split(',')[1];};r.onerror=()=>{t.chunkError=true;};"
                        + "r.readAsDataURL(t.blob.slice(" + offset + "," + end + "));return {started:true};})()");
        evaluateObject(expression, result -> {
            if (result == null || !result.optBoolean("started")) { failExport(item, "صفحه تغییر کرد؛ دوباره خروجی بگیرید."); return; }
            main.postDelayed(() -> pollBlobChunk(item, offset, end, 0), 20);
        });
    }

    private void pollBlobChunk(Download item, int offset, int end, int attempt) {
        if (!isCurrent(item)) return;
        if (attempt > 200) { failExport(item, "دریافت خروجی بیش از حد طول کشید. دوباره تلاش کنید."); return; }
        evaluateObject(blobTaskExpression(item, "({chunk:t.chunk,error:t.chunkError})"), result -> {
            if (!isCurrent(item)) return;
            if (result == null || result.optBoolean("error")) { failExport(item, "دریافت خروجی کامل نشد."); return; }
            if (result.isNull("chunk") || !result.has("chunk")) {
                main.postDelayed(() -> pollBlobChunk(item, offset, end, attempt + 1), 40);
                return;
            }
            String encoded = result.optString("chunk");
            if (encoded.length() > (BLOB_CHUNK_BYTES * 4 / 3) + 4) { failExport(item, "اندازه خروجی معتبر نیست."); return; }
            io.execute(() -> {
                try {
                    if (item.cancelled) return;
                    byte[] bytes = Base64.decode(encoded, Base64.DEFAULT);
                    if (bytes.length != end - offset || item.stream == null) throw new IOException("Invalid chunk");
                    item.stream.write(bytes);
                    main.post(() -> readBlobChunk(item, end));
                } catch (Exception e) { main.post(() -> failExport(item, "فایل ذخیره نشد. فضای آزاد گوشی را بررسی کنید.")); }
            });
        });
    }

    private String blobTaskExpression(Download item, String value) {
        return "(()=>{if(location.origin!==" + JSONObject.quote(UrlPolicy.ORIGIN) + ")return null;const s=window["
                + JSONObject.quote(blobStore) + "],t=s&&s.tasks[" + JSONObject.quote(item.id)
                + "];return t?" + value + ":null;})()";
    }

    private void evaluateObject(String expression, Consumer<JSONObject> callback) {
        if (destroyed || rendererGone) return;
        web.evaluateJavascript("JSON.stringify(" + expression + ")", value -> {
            JSONObject result = null;
            try {
                Object parsed = new JSONTokener(value).nextValue();
                if (parsed instanceof String) result = new JSONObject((String) parsed);
            } catch (Exception ignored) { }
            callback.accept(result);
        });
    }

    private void finishExport(Download item) {
        if (!isCurrent(item)) return;
        clearBlobTask(item);
        export = null;
        toast("فایل ذخیره شد: " + item.name);
    }

    private void failExport(Download item, String message) {
        if (!isCurrent(item)) return;
        cancelExport(item);
        toast(message);
    }

    private void cancelExport(Download item) {
        item.cancelled = true;
        clearBlobTask(item);
        if (export == item) export = null;
        io.execute(() -> {
            try { closeBlobStream(item); } catch (IOException ignored) { }
            if (item.destination != null) {
                try { DocumentsContract.deleteDocument(getContentResolver(), item.destination); }
                catch (Exception ignored) { /* Some providers cannot delete an incomplete document. */ }
            }
        });
    }

    private void clearBlobTask(Download item) {
        if (item.blob && !destroyed && !rendererGone && UrlPolicy.isInternal(web.getUrl())) {
            web.evaluateJavascript("(()=>{const s=window[" + JSONObject.quote(blobStore) + "];if(s){delete s.tasks["
                    + JSONObject.quote(item.id) + "];const u=" + JSONObject.quote(item.url)
                    + ";if(s.items[u]){s.bytes-=s.items[u].size;delete s.items[u];}delete s.names[u];}})()", null);
        }
    }

    private void closeBlobStream(Download item) throws IOException {
        OutputStream stream = item.stream;
        item.stream = null;
        if (stream != null) { try { stream.flush(); } finally { stream.close(); } }
    }

    private boolean isCurrent(Download item) { return !destroyed && export == item && !item.cancelled; }

    private static String cleanMime(String mime) {
        if (mime == null) return "application/octet-stream";
        String base = mime.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
        return base.matches("[a-z0-9.+_-]+/[a-z0-9.+_-]+") ? base : "application/octet-stream";
    }

    private static String defaultBlobName(String mime) {
        switch (mime) {
            case "application/pdf": return "TehranVolt-export.pdf";
            case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "TehranVolt-export.xlsx";
            case "application/vnd.ms-excel": return "TehranVolt-export.xls";
            case "text/csv": return "TehranVolt-export.csv";
            case "image/png": return "TehranVolt-export.png";
            case "image/jpeg": return "TehranVolt-export.jpg";
            default: return "TehranVolt-export.bin";
        }
    }

    private void showError(String message) {
        pageFailed = true;
        progress.setVisibility(View.GONE);
        errorMessage.setText(message);
        errorPanel.setVisibility(View.VISIBLE);
    }

    private void navigateBack() {
        if (!rendererGone && web.canGoBack() && !pageFailed) web.goBack();
        else new AlertDialog.Builder(this).setMessage("از تهران‌ولت خارج شوید؟")
                .setPositiveButton("خروج", (dialog, which) -> finish())
                .setNegativeButton("ماندن", null).show();
    }

    @Override public void onBackPressed() { navigateBack(); }

    @Override protected void onSaveInstanceState(Bundle state) {
        Bundle browserState = new Bundle();
        if (!rendererGone) web.saveState(browserState);
        state.putBundle("browser", browserState);
        super.onSaveInstanceState(state);
    }

    @Override protected void onPause() {
        CookieManager.getInstance().flush();
        if (!rendererGone) web.onPause();
        super.onPause();
    }

    @Override protected void onResume() {
        super.onResume();
        if (web != null && !rendererGone) web.onResume();
    }

    @Override protected void onDestroy() {
        completeUpload(null);
        if (export != null) cancelExport(export);
        destroyed = true;
        main.removeCallbacksAndMessages(null);
        if (!rendererGone) {
            web.stopLoading();
            if (web.getParent() instanceof android.view.ViewGroup)
                ((android.view.ViewGroup) web.getParent()).removeView(web);
            web.destroy();
        }
        io.shutdown();
        super.onDestroy();
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private void toast(String text) { if (!destroyed) Toast.makeText(this, text, Toast.LENGTH_LONG).show(); }

    private final class Download {
        String url;
        String mime;
        String name;
        String id;
        String userAgent = web.getSettings().getUserAgentString();
        boolean blob;
        int size;
        Uri destination;
        volatile boolean cancelled;
        OutputStream stream; // Read and written only on the single I/O executor.
    }
}
