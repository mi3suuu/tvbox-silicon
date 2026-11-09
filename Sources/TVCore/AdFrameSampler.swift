#if canImport(UIKit)
import AVFoundation
import CoreImage
import UIKit

/// 从正在播放的 `AVPlayerItem` 里按节奏抓帧，算出 dHash。
///
/// 为什么用 `AVPlayerItemVideoOutput` 而不是 `AVAssetImageGenerator`：
/// 后者会**另起一条解码链**去解同一份媒体，和 `AVPlayer` 抢解码器，
/// 实测会造成卡顿与音画不同步。`AVPlayerItemVideoOutput` 附着在**已有的**
/// 播放管线上，直接拿已经解好的帧，零额外解码。
///
/// 代价：它只在**播放中**有帧可拿。离线扫全集需要另建 `AVAssetReader`，
/// 但用户场景是「边播边识别」，用这个更合适。
@MainActor
public final class AdFrameSampler {
    /// 采样间隔（秒）。1 秒够用：dHash 对 1 秒内的画面变化不敏感，
    /// 而广告通常持续十几秒，1 秒 1 帧能拿到十几个样本。
    public var interval: TimeInterval = 1.0

    private var output: AVPlayerItemVideoOutput?
    /// 记住挂在哪条 item 上 —— `AVPlayerItemVideoOutput` 不保留 owner 指针，
    /// 摘除时必须显式拿到当初那条 item，不能靠 `superlayer` 猜。
    private weak var attachedItem: AVPlayerItem?
    private var timer: Timer?
    private var lastSample: TimeInterval = -1

    public init() {}

    /// 开始对一个 item 采样。已在进行中会先停掉。
    public func start(item: AVPlayerItem, onHash: @escaping @Sendable (UInt64, TimeInterval) -> Void) {
        stop()
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(out)
        output = out
        attachedItem = item
        lastSample = -1

        // 用 Timer 而不是 CADisplayLink：我们只要 1Hz，displaylink 是 60Hz，白白唤醒 CPU。
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick(item: item, onHash: onHash) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let output, let item = attachedItem { item.remove(output) }
        output = nil
        attachedItem = nil
        lastSample = -1
    }

    /// 把某个 item 上的 output 摘掉（换集时调用）。
    public func detach(from item: AVPlayerItem) {
        if let output { item.remove(output) }
        stop()
    }

    /// 暂停时也别继续采样：`copyPixelBuffer` 会拿到同一帧，
    /// 同一哈希被重复喂进 `AdMatcher` 会把它误判成「连续命中」。
    public var isRunning: Bool { timer != nil }

    private func tick(item: AVPlayerItem, onHash: @escaping @Sendable (UInt64, TimeInterval) -> Void) {
        guard let output else { return }
        let now = CACurrentMediaTime()
        guard now - lastSample >= interval else { return }

        let time = item.currentTime()
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        // 没在播就没有新帧，取到的是旧画面，会污染指纹。
        guard item.status == .readyToPlay else { return }

        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }

        lastSample = now
        guard let hash = Self.dHash(from: buffer) else { return }
        onHash(hash, seconds)
    }

    /// CVPixelBuffer → 9×8 灰度 → dHash。
    ///
    /// 用 CoreImage 一次性缩到 9×8：`CILanczosScaleTransform` 之后
    /// 只读 72 个像素，比先缩到中等尺寸再逐点采样稳定得多
    ///（直接跳跃采样会受源分辨率影响，同一帧在不同码率下算出不同哈希）。
    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 离线抓一段的哈希序列，用于「标记为广告」。
    ///
    /// 用 `AVAssetImageGenerator` 而不是 `AVPlayerItemVideoOutput`：
    /// 标注是**一次性**动作（用户主动点按钮），不需要实时，允许短暂占用解码器；
    /// 而 `AVPlayerItemVideoOutput` 只能拿「当前正在播的那一帧」，抓不了过去的时间段。
    ///
    /// `maximumSize` 设成 9×8 的整数倍并开 `appliesPreferredTrackTransform`，
    /// 让生成器直接吐出小图 —— 比抓全尺寸再缩快一个数量级。
    public nonisolated static func hashes(for asset: AVAsset, from start: Double, to end: Double,
                                   interval: Double = 1.0) async -> [UInt64] {
        guard end > start, interval > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // 缩放目标：9×8 的 4 倍，够 CI 缩到 9×8，又比全尺寸便宜得多。
        generator.maximumSize = CGSize(width: 36, height: 32)

        var result: [UInt64] = []
        var t = start
        while t < end {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image,
               let hash = dHash(from: cg) {
                result.append(hash)
            }
            t += interval
        }
        return result
    }

    /// CGImage → 9×8 灰度 → dHash。
    public nonisolated static func dHash(from image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        guard let ctx = CGContext(data: &pixels, width: 9, height: 8,
                                  bitsPerComponent: 8, bytesPerRow: 9,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        return AdHash.dHash(gray: pixels)
    }

    public nonisolated static func dHash(from buffer: CVPixelBuffer) -> UInt64? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }

        let ci = CIImage(cvPixelBuffer: buffer)
        let target = CGSize(width: 9, height: 8)
        let sx = target.width / ci.extent.width
        let sy = target.height / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        ciContext.render(scaled, toBitmap: &pixels, rowBytes: 9,
                         bounds: CGRect(x: 0, y: 0, width: 9, height: 8),
                         format: .L8, colorSpace: colorSpace)
        return AdHash.dHash(gray: pixels)
    }
}
#endif
