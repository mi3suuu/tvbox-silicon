// 这个文件只用到 AVFoundation / CoreImage / CoreVideo（`AVPlayerItemVideoOutput`、
// `CIContext`、`CVPixelBuffer`），三者 macOS / tvOS 全都有 —— 之前的 `canImport(UIKit)`
// 把整类挡在非 iOS 平台外面，于是跨平台的 `PlaybackView` 报 `cannot find 'AdFrameSampler'`。
import AVFoundation
import CoreImage
import CoreVideo

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
    /// CGImage → 9×8 灰度 → dHash。
    ///
    /// ⛔ 必须与 `dHash(from: CVPixelBuffer)` 走**同一套缩放**（CIImage + 同一个
    /// `ciContext`），否则同一条广告"标注时"和"播放时"算出的哈希天然差几个 bit。
    ///
    /// 实测（157 真实帧，A/B 两档转码 + 负对照）：
    ///   · 标注用 `CGContext.interpolationQuality = .medium` 二次重采样、
    ///     播放用 `CIImage.transformed` 一次缩放 →
    ///     同源自己标自己放只有 **80%**（距离均值 7.3，阈值 8），跨源 **85%**（均值 8.0，压在阈值上）。
    ///   · 两边统一走 CIImage → 同源 **100%**（均值 5.3）、跨源 **100%**（均值 5.5）。
    /// 阈值是 8，均值 7.3 意味着「一半的帧擦着阈值过」——这正是"标了却不跳/时灵时不灵"的根因：
    /// `AdMatcher` 要求连续 3 帧命中才确认，单帧 80% 的成功率会把连续 3 帧的确认概率打到 51%。
    ///
    /// 改动只影响**新标注**的指纹。旧库里用旧实现算出来的哈希距离会略微变大，
    /// 仍落在阈值内可用（实测旧库 85%），不需要强制清库。
    /// 纯色帧不入库（见 `AdHash.contrast` 的说明）。
    ///
    /// 返回 nil 表示「这一帧没有可用细节，跳过」——与「解码失败」同样处理，
    /// 调用方本来就会跳过 nil。区别只在日志含义。
    public nonisolated static func dHash(from image: CGImage) -> UInt64? {
        let base = CIImage(cgImage: image)
        guard base.extent.width > 0, base.extent.height > 0 else { return nil }
        let scaled = base.transformed(by: CGAffineTransform(scaleX: 9 / base.extent.width,
                                                            y: 8 / base.extent.height))
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        ciContext.render(scaled, toBitmap: &pixels, rowBytes: 9,
                         bounds: CGRect(x: 0, y: 0, width: 9, height: 8),
                         format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        // 纯色帧不入库：dHash 对纯色恒为 0，跨帧距离 0，会造成误命中断言。
        guard AdHash.isUsableFrame(gray: pixels) else { return nil }
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
        // 同上：纯色帧（黑场/白场/单色板）直接丢弃，不进匹配也不入库。
        guard AdHash.isUsableFrame(gray: pixels) else { return nil }
        return AdHash.dHash(gray: pixels)
    }
}

// MARK: - 同一支广告的判定（跨源）

/// 「两个指纹是不是同一支广告」—— 跨源复用就靠这一个判据。
///
/// 用户的实际场景是「A 源 A 视频里标过，B 源 B 视频里又遇到同一支广告」，
/// 所以这个判据要在**转码差异**下仍然成立。实测（两档转码 A/B + 负对照）：
///
///   · 标注与播放走同一套缩放时：跨源逐帧距离 4…8（均值 5.5），负对照 15…24（均值 18.5）
///   · 两侧实现不一致时：同源自己标自己放只有 80%（均值 7.3），跨源 85%（均值 8.0，贴阈值）
///
/// 阈值 8 在两侧一致后有明显余量（好帧 ≤8、坏帧 ≥15），不需要放宽 ——
/// 放宽只会让误跳变多，而误跳比漏跳代价高得多。
public enum AdMatch {
    /// 两个指纹库（一支广告 vs 另一支广告）是否同一支。
    ///
    /// 判据：取**最像的那一对**采样点，距离 ≤ `AdMatcher.threshold`。
    /// 用最小距离而不是平均值：两支广告的**开头卡或结尾品牌板**常常一模一样
    ///（同一家广告主），只靠平均值会被"其它镜头完全不同"拉高而判成两支。
    /// 只取最小距离的风险是偶发单帧撞上，所以真正的误跳防线在
    /// `AdMatcher.confirmFrames`（连续多帧）那一层，不在这里。
    public static func sameAd(_ a: [UInt64], _ b: [UInt64],
                              threshold: Int = AdMatcher.threshold) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        for x in a {
            for y in b {
                if AdHash.hamming(x, y) <= threshold { return true }
            }
        }
        return false
    }

    /// 指纹库里是否已经有这支广告（跨源去重用）。
    public static func contains(_ hashes: [UInt64], in library: [AdSignature]) -> Bool {
        library.contains { sameAd(hashes, $0.hashes) }
    }
}
