package ir.tehbatri.admin;

import java.net.URI;
import java.util.Locale;

/** Shared allowlist: cookies and app navigation never leave this exact HTTPS origin. */
final class UrlPolicy {
    static final String HOME = "https://tehbatri.ir/admin";
    static final String ORIGIN = "https://tehbatri.ir";

    private UrlPolicy() { }

    static boolean isInternal(String value) {
        if (value == null) return false;
        try {
            URI uri = new URI(value);
            return "https".equalsIgnoreCase(uri.getScheme())
                    && "tehbatri.ir".equalsIgnoreCase(uri.getHost())
                    && uri.getRawUserInfo() == null
                    && (uri.getPort() == -1 || uri.getPort() == 443);
        } catch (Exception ignored) {
            return false;
        }
    }

    static boolean isInternalBlob(String value) {
        return value != null && value.startsWith("blob:") && isInternal(value.substring(5));
    }

    static boolean isExternalAllowed(String value) {
        if (value == null || value.length() > 8192) return false;
        try {
            URI uri = new URI(value);
            String scheme = uri.getScheme();
            if (scheme == null) return false;
            switch (scheme.toLowerCase(Locale.ROOT)) {
                case "https":
                    return uri.getHost() != null && uri.getRawUserInfo() == null;
                case "tel":
                case "mailto":
                    return uri.getRawSchemeSpecificPart() != null
                            && !uri.getRawSchemeSpecificPart().isEmpty();
                default:
                    return false;
            }
        } catch (Exception ignored) {
            return false;
        }
    }

    static String safeFileName(String value) {
        if (value == null) value = "TehranVolt-export";
        value = value.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_")
                .replaceAll("^[.\\s]+", "").trim();
        if (value.isEmpty()) value = "TehranVolt-export";
        if (value.length() > 120) {
            int dot = value.lastIndexOf('.');
            String extension = dot > 0 && value.length() - dot <= 12 ? value.substring(dot) : "";
            value = value.substring(0, 120 - extension.length()) + extension;
        }
        return value;
    }
}
