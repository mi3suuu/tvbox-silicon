// 方向交叉校验工具：用 Apple Vision OCR 统计「横排文本框数」判断截图的正立方向。
// 与 measure.py 的「高频边缘各向异性」是**两条完全独立的方法**，
// 两者的判定必须一致，否则说明各向异性判据不可信。
//
// 用法：
//   swiftc -O tools/onemeasure/ocrrot.swift -o /tmp/ocrrot && /tmp/ocrrot <png>
//   输出三行：rot=  0 / 90 / 270  各自 total / horizontal / vertical 文本框数
//   正立方向 = horizontal 计数最大的那个旋转角。
//
// 说明：这用的是 macOS 本地 Vision 框架（CPU/ANE 上的文字识别），
// 不是视觉大模型，不涉及图像理解或坐标猜测。
import Foundation
import Vision
import AppKit

func run(_ path: String, _ rot: Int) -> (Int, Int, Int, Double) {
    guard let img = NSImage(contentsOfFile: path),
          let data = img.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: data),
          let cg0 = bmp.cgImage else { return (0, 0, 0, 0) }
    var cg = cg0
    if rot != 0 {
        let w = cg0.width, h = cg0.height
        let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: CGFloat(rot) * .pi / 180)
        ctx.draw(cg0, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                                 width: CGFloat(w), height: CGFloat(h)))
        cg = ctx.makeImage()!
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    let res = req.results ?? []
    var hor = 0, ver = 0
    var conf = 0.0
    for o in res {
        let b = o.boundingBox
        if b.width > b.height { hor += 1 } else { ver += 1 }
        conf += Double(o.topCandidates(1).first?.confidence ?? 0)
    }
    return (res.count, hor, ver, res.isEmpty ? 0 : conf / Double(res.count))
}

guard CommandLine.arguments.count > 1 else {
    print("usage: ocrrot <png>")
    exit(1)
}
let path = CommandLine.arguments[1]
for rot in [0, 90, 270] {
    let (n, h, v, c) = run(path, rot)
    print(String(format: "rot=%3d total=%3d horizontal=%3d vertical=%3d conf=%.3f",
                 rot, n, h, v, c))
}
