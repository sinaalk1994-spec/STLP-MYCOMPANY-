package ir.tehbatri.admin;

/** Standalone regression checks: javac UrlPolicy.java UrlPolicyTest.java, then run this class. */
public final class UrlPolicyTest {
    private static int checked;

    public static void main(String[] args) {
        allowInternal("https://tehbatri.ir/admin");
        allowInternal("https://TEHBATRI.IR:443/admin/members?page=2#table");
        allowInternal("https://tehbatri.ir/admin?next=https%3A%2F%2Fexample.com");

        String[] blocked = {
                null, "", "/admin", "http://tehbatri.ir/admin", "https://tehbatri.ir:444/admin",
                "https://www.tehbatri.ir/admin", "https://tehbatri.ir.evil.test/admin",
                "https://evil.test/tehbatri.ir", "https://tehbatri.ir@evil.test/admin",
                "https://evil.test@tehbatri.ir/admin", "https://tehbatri.ir./admin",
                "https://tehbatri%2eir/admin", "https://tehbatri.ir\\@evil.test/admin",
                "file:///data/data/ir.tehbatri.admin/files/private", "content://documents/private",
                "javascript:alert(1)", "data:text/html,hello", "intent://tehbatri.ir/admin#Intent;end",
                "blob:https://tehbatri.ir/id"
        };
        for (String value : blocked) expect(!UrlPolicy.isInternal(value), "internal blocked: " + value);

        expect(UrlPolicy.isInternalBlob("blob:https://tehbatri.ir/report-id"), "trusted blob");
        expect(!UrlPolicy.isInternalBlob("blob:https://tehbatri.ir.evil.test/id"), "foreign blob");
        expect(!UrlPolicy.isInternalBlob("blob:http://tehbatri.ir/id"), "insecure blob");
        expect(!UrlPolicy.isInternalBlob("blob:null/id"), "opaque blob");
        expect(!UrlPolicy.isInternalBlob(null), "null blob");

        expect(UrlPolicy.isExternalAllowed("https://example.com/help"), "HTTPS browser link");
        expect(UrlPolicy.isExternalAllowed("tel:+982112345678"), "dialler link");
        expect(UrlPolicy.isExternalAllowed("mailto:info@example.com"), "email link");
        for (String value : new String[]{"http://example.com", "intent://example", "javascript:1", "file:///tmp/one", "content://anything", "https://user@example.com", null})
            expect(!UrlPolicy.isExternalAllowed(value), "external blocked: " + value);

        expect("گزارش.xlsx".equals(UrlPolicy.safeFileName("گزارش.xlsx")), "Persian filename preserved");
        expect("TehranVolt-export".equals(UrlPolicy.safeFileName(null)), "missing filename fallback");
        expect("_private_credential.pdf".equals(UrlPolicy.safeFileName("../private/credential.pdf")), "path separators scrubbed");
        expect(!UrlPolicy.safeFileName("file\n\r\t.pdf").contains("\n"), "control characters scrubbed");
        String longName = UrlPolicy.safeFileName("گ".repeat(200) + ".xlsx");
        expect(longName.length() <= 120 && longName.endsWith(".xlsx"), "long filename retains extension");
        System.out.println("UrlPolicy: " + checked + " checks passed.");
    }

    private static void allowInternal(String value) { expect(UrlPolicy.isInternal(value), "internal allowed: " + value); }

    private static void expect(boolean condition, String description) {
        checked++;
        if (!condition) throw new AssertionError(description);
    }
}
