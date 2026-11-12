import XCTest
@testable import TVCore

/// Guards the m3u8 rewriting a browser's playback depends on.
///
/// This chain had **no tests at all**, which is how a regression that broke every AES-128 and fMP4
/// playlist slipped through: the rewrite dropped the opening quote of `URI="…"`, leaving a lone
/// closing quote that no parser accepts. Every case below is one that failed or could fail silently.
final class WebCastPlaylistRewriteTests: XCTestCase {
    /// The playlist's own address. `rewriteM3U8` resolves references against its *directory*,
    /// which is this URL with the last path component removed — so relative segments land in
    /// `.../live/`, not `.../live/sub/`.
    private let base = URL(string: "https://cdn.example.com/live/sub/index.m3u8")!

    private func rewrite(_ text: String, headerID: String? = "H", token: String? = nil) -> String {
        let data = WebCastServer.rewriteM3U8(Data(text.utf8), base: base, headerID: headerID, token: token)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Quoted attributes (the regression)

    func testKeyAttributeKeepsBalancedDoubleQuotes() {
        let out = rewrite(#"#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1"#)
        // A quoted-string must survive: exactly two double quotes, and the URI is still quoted.
        XCTAssertEqual(out.filter { $0 == "\"" }.count, 2, "URI= must stay a quoted-string: \(out)")
        XCTAssertTrue(out.contains(#"URI="/proxy/"#), "the opening quote must be kept: \(out)")
        XCTAssertFalse(out.contains(#"URI=/proxy/"#.replacingOccurrences(of: "\"", with: "")), "URI must not lose its quote: \(out)")
    }

    func testMapAttributeKeepsBalancedDoubleQuotes() {
        let out = rewrite(#"#EXT-X-MAP:URI="init.mp4""#)
        XCTAssertEqual(out.filter { $0 == "\"" }.count, 2, out)
    }

    func testSingleQuotedAttributeIsAlsoRewritten() {
        let out = rewrite("#EXT-X-KEY:METHOD=AES-128,URI='key.bin',IV=0x1")
        XCTAssertEqual(out.filter { $0 == "'" }.count, 2, "single-quoted URI must stay balanced: \(out)")
        XCTAssertTrue(out.contains("/proxy/"), "a single-quoted key must still be proxied: \(out)")
    }

    func testMediaAttributeAmongOtherQuotedValues() {
        let out = rewrite(#"#EXT-X-MEDIA:TYPE=AUDIO,URI="audio.m3u8",GROUP-ID="a""#)
        // URI plus GROUP-ID: four quotes, and only the URI one is rewritten.
        XCTAssertEqual(out.filter { $0 == "\"" }.count, 4, out)
        XCTAssertTrue(out.contains("/proxy/"), out)
    }

    // MARK: - Relative references with a query

    func testSignedSegmentKeepsItsQuery() {
        // `appendingPathComponent` used to turn this into a *path* containing "?" with no query,
        // so the CDN saw a different path and answered 404 for every signed segment.
        let out = rewrite("seg.ts?sign=abc&t=1")
        XCTAssertTrue(out.hasPrefix("/proxy/"), out)
        // The whole signed address is percent-escaped into one path segment. `?` and `&` must be
        // encoded — otherwise the segment's own query would be read as ours — while `=` is a legal
        // character in a path segment and stays as-is.
        XCTAssertTrue(out.contains("%3Fsign=abc%26t=1"), "the segment's own ?/& must be escaped: \(out)")
        let wrapped = out.replacingOccurrences(of: "/proxy/", with: "")
            .split(separator: "?").first.map(String.init) ?? ""
        let decoded = wrapped.removingPercentEncoding ?? ""
        XCTAssertEqual(decoded, "https://cdn.example.com/live/sub/seg.ts?sign=abc&t=1")
    }

    func testRootRelativeReferenceKeepsItsOwnDepth() {
        // A leading "/" is relative to the host, not to the playlist's folder.
        let out = rewrite("/root/seg.ts")
        let decoded = (out.replacingOccurrences(of: "/proxy/", with: "")
            .split(separator: "?").first.map(String.init) ?? "").removingPercentEncoding ?? ""
        XCTAssertEqual(decoded, "https://cdn.example.com/root/seg.ts", "a root-relative path must not gain a folder: \(out)")
    }

    func testAbsoluteSegmentIsPassedThrough() {
        let out = rewrite("https://other.example.com/a/seg.ts")
        let decoded = (out.replacingOccurrences(of: "/proxy/", with: "")
            .split(separator: "?").first.map(String.init) ?? "").removingPercentEncoding ?? ""
        XCTAssertEqual(decoded, "https://other.example.com/a/seg.ts")
    }

    // MARK: - Our own query parameters

    func testHeaderIDIsCarried() {
        let out = rewrite("seg.ts", headerID: "ABC")
        XCTAssertTrue(out.hasSuffix("?h=ABC"), out)
    }

    func testTokenIsCarriedAlongsideHeaderID() {
        // `/proxy` sits behind the login gate: a segment URL without `token` is answered 401 as
        // soon as the viewer has set a password, so the second segment would fail.
        let out = rewrite("seg.ts", headerID: "ABC", token: "pw")
        XCTAssertTrue(out.contains("h=ABC"), out)
        XCTAssertTrue(out.contains("token=pw"), out)
    }

    func testNoQueryWhenNeitherIsPresent() {
        let out = rewrite("seg.ts", headerID: nil, token: nil)
        XCTAssertFalse(out.contains("?"), "nothing to carry, so no query: \(out)")
    }

    // MARK: - Byte ranges

    func testByteRangeForms() {
        let total = 1_000
        XCTAssertEqual(WebCastServer.byteRange("bytes=0-99", total: total), 0..<100)
        XCTAssertEqual(WebCastServer.byteRange("bytes=500-", total: total), 500..<1000)
        XCTAssertEqual(WebCastServer.byteRange("bytes=-100", total: total), 900..<1000)
        // Out of range and malformed values fall back to nil (the caller then answers 416).
        XCTAssertNil(WebCastServer.byteRange("bytes=2000-", total: total))
        XCTAssertNil(WebCastServer.byteRange("bytes=9-3", total: total))
        XCTAssertNil(WebCastServer.byteRange("bytes=-0", total: total))
        XCTAssertNil(WebCastServer.byteRange("bytes=abc-def", total: total))
    }

    // MARK: - MIME mapping

    func testAVFoundationIdentifiersBecomeBrowserMIMETypes() {
        // `CloudByteStream.contentType()` answers with a UTI; a browser rejects those outright.
        XCTAssertEqual(WebCastVirtualStreams.mime(forUTI: "public.mpeg-4"), "video/mp4")
        XCTAssertEqual(WebCastVirtualStreams.mime(forUTI: "com.apple.quicktime-movie"), "video/quicktime")
        XCTAssertEqual(WebCastVirtualStreams.mime(forUTI: "com.apple.m4v-video"), "video/mp4")
        // Something already shaped like a MIME type passes through untouched.
        XCTAssertEqual(WebCastVirtualStreams.mime(forUTI: "video/mp4"), "video/mp4")
    }
}
