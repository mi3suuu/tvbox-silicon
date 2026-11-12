import Foundation
import Vision
import AppKit

// Prints the text in a screenshot with its position, so a page can be checked without a vision model.
guard CommandLine.arguments.count > 1 else {
    print("usage: ocr <png>")
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: url),
      let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let cg = bitmap.cgImage else {
    print("cannot read image")
    exit(1)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
try handler.perform([request])
let results = request.results ?? []
// Sorted top to bottom, then left to right: the order a page reads in.
let sorted = results.sorted { a, b in
    let ay = 1 - a.boundingBox.midY, by = 1 - b.boundingBox.midY
    if abs(ay - by) > 0.01 { return ay < by }
    return a.boundingBox.minX < b.boundingBox.minX
}
for observation in sorted {
    guard let top = observation.topCandidates(1).first else { continue }
    let b = observation.boundingBox
    print(String(format: "%.3f %.3f  %@", 1 - b.midY, b.minX, top.string))
}
