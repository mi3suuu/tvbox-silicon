import Foundation

/// Serves the app's own playback schemes to a browser.
///
/// Three of the app's addresses are not HTTP at all: a cloud drive's file (`tvbox-cloud`), an
/// encrypted Hongguo MP4 (`tvbox-hongguo`), and a repackaged DASH pair (`tvbox-dash`). AVPlayer
/// reads them through a resource loader, which a browser has no equivalent of — so before this,
/// the web page could only refuse them ("play it on the phone").
///
/// Each one, however, ultimately answers "give me bytes N..M of a file whose length is L". That is
/// exactly what an HTTP `Range` request is, so the relay below turns the three into ordinary
/// ranged responses. The browser then plays them like any other file, and seeking works because
/// every request is answered from the range it asked for.
enum WebCastVirtualStreams {
    /// A file the relay can serve by byte range, whatever produced it.
    enum Source {
        /// A cloud drive file: length known up front, chunks fetched from the CDN.
        case cloud(CloudByteStream)
        /// An encrypted Hongguo MP4: length comes from the file's own index.
        case hongguo(HongguoByteStream)
        /// A DASH pair rendered as an HLS playlist; the playlist is small and served whole.
        case playlist(String)

        /// The MIME type, once known. A playlist knows immediately; the others sniff their head.
        var immediateType: String? {
            if case .playlist = self { return "application/vnd.apple.mpegurl" }
            return nil
        }
    }

    /// Resolves one of the app's own scheme addresses into something servable, or nil when the
    /// address is not one of ours (the caller then falls back to a plain HTTP fetch).
    static func source(for url: URL) async -> Source? {
        switch url.scheme {
        case CloudStreams.scheme:
            guard let stream = await CloudStreams.byteStream(for: url) else { return nil }
            return .cloud(stream)
        case HongguoStreams.scheme:
            guard let stream = await HongguoStreams.byteStream(for: url) else { return nil }
            return .hongguo(stream)
        case DashStreams.scheme:
            guard let text = await DashStreams.playlist(for: url) else { return nil }
            return .playlist(text)
        default:
            return nil
        }
    }

    /// AVFoundation's container identifier → the MIME type a browser understands.
    static func mime(forUTI uti: String) -> String {
        // A UTI that is already a MIME type (some callers sniff it that way) passes through.
        if uti.contains("/") { return uti }
        switch uti {
        case "public.mpeg-4", "com.apple.m4v-video": return "video/mp4"
        case "com.apple.quicktime-movie": return "video/quicktime"
        case "public.mpeg-2-transport-stream": return "video/mp2t"
        case "org.xiph.flac": return "audio/flac"
        case "public.mp3", "public.mp3-audio": return "audio/mpeg"
        case "public.mpeg-4-audio", "com.apple.m4a-audio": return "audio/mp4"
        case "public.aac-audio": return "audio/aac"
        default: return "application/octet-stream"
        }
    }
}

extension WebCastVirtualStreams.Source {
    /// The file's total length, or nil for a playlist (whose length is just its text).
    func length() async -> Int? {
        switch self {
        case .cloud(let stream): return await stream.length
        case .hongguo(let stream):
            guard let index = try? await stream.metadata() else { return nil }
            return index.length
        case .playlist: return nil
        }
    }

    /// Bytes `offset..<offset+count`, clamped to the file's end.
    func read(at offset: Int, count: Int) async throws -> Data {
        switch self {
        case .cloud(let stream):
            let total = await stream.length
            guard offset < total else { return Data() }
            return try await stream.read(at: offset, count: min(count, total - offset))
        case .hongguo(let stream):
            let total = try await stream.metadata().length
            guard offset < total else { return Data() }
            // `bounded: false` is required here. The bounded read throttles itself against the
            // player's playhead (`while sampleTime > position + 60s sleep`), and `position` only
            // advances from AVPlayer callbacks. A browser never calls those, so position stays 0
            // and any read past the 60-second mark would spin forever without ever answering the
            // HTTP request — sequential playback, not just seeking. The relay is its own pacing
            // (one range at a time, bounded by the browser's requests), so it asks for the bytes.
            return try await stream.read(at: offset, count: min(count, total - offset), bounded: false)
        case .playlist(let text):
            let all = Data(text.utf8)
            guard offset < all.count else { return Data() }
            return all.subdata(in: offset..<min(offset + count, all.count))
        }
    }

    /// The MIME type a browser will accept.
    ///
    /// `CloudByteStream.contentType()` answers with an **AVFoundation UTI** (`public.mpeg-4`,
    /// `com.apple.quicktime-movie`) because that is what AVPlayer wants. A browser does not: Chrome
    /// checks media types against a short whitelist and rejects `public.mpeg-4` outright
    /// (`MEDIA_ERR_SRC_NOT_SUPPORTED`). So the UTI is mapped back to a real MIME type here, using the
    /// same table `LocalMediaServer` already serves local files with.
    func contentType() async -> String {
        if let immediateType { return immediateType }
        if case .cloud(let stream) = self, let uti = try? await stream.contentType() {
            return WebCastVirtualStreams.mime(forUTI: uti)
        }
        // A decrypted Hongguo file is always the clear MP4 the index describes.
        if case .hongguo = self { return "video/mp4" }
        return "application/octet-stream"
    }
}
