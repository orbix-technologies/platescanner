import CoreGraphics
import Foundation
import Vision

/// Helpers shared by the dedicated section passes (mirrors `CropOcr.kt`).
enum CropOcr {
  private static let numberRun = try! NSRegularExpression(pattern: "\\d{5,}")

  /// The plate number as read, in pixel coordinates (top-left origin).
  struct Anchor {
    /// Box of every character of the number's line (`.zero` if unknown).
    let rects: [CGRect]
    /// Index of the number's first and one-past-last digit.
    let start: Int
    let end: Int

    var first: CGRect { rects[start] }
    var last: CGRect { rects[end - 1] }
    var top: CGFloat { rects[start..<end].map { $0.minY }.min()! }
    var bottom: CGFloat { rects[start..<end].map { $0.maxY }.max()! }
    var height: CGFloat { bottom - top }
  }

  /// The tallest run of 5+ digits read on one line, or nil.
  static func numberAnchor(
    _ observations: [VNRecognizedTextObservation], width: CGFloat, height: CGFloat
  ) -> Anchor? {
    var best: Anchor?
    for obs in observations {
      guard let candidate = obs.topCandidates(1).first else { continue }
      let s = candidate.string
      var rects: [CGRect] = []
      var i = s.startIndex
      while i < s.endIndex {
        let next = s.index(after: i)
        if let b = (try? candidate.boundingBox(for: i..<next))?.boundingBox {
          rects.append(
            CGRect(
              x: b.minX * width, y: (1 - b.maxY) * height,
              width: b.width * width, height: b.height * height))
        } else {
          rects.append(.zero)
        }
        i = next
      }
      let range = NSRange(s.startIndex..., in: s)
      guard let m = numberRun.firstMatch(in: s, range: range),
        let r = Range(m.range, in: s)
      else { continue }
      let start = s.distance(from: s.startIndex, to: r.lowerBound)
      let end = s.distance(from: s.startIndex, to: r.upperBound)
      guard end <= rects.count, !rects[start..<end].contains(.zero) else { continue }
      let a = Anchor(rects: rects, start: start, end: end)
      if best == nil || a.height > best!.height { best = a }
    }
    return best
  }

  /// OCR of `area` (pixels, top-left origin) of `image` alone: scaled so its
  /// height is `size` px, centred on a white page with a margin of its own
  /// size on every side, optionally reduced to black and white first.
  static func read(_ image: CGImage, area: CGRect, size: CGFloat, blackAndWhite: Bool) -> String? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let src = area.integral.intersection(bounds)
    guard src.width >= 6, src.height >= 6, var crop = image.cropping(to: src) else { return nil }
    let scale = min(max(size / src.height, 0.5), 5)
    let w = max(Int(src.width * scale), 1)
    let h = max(Int(src.height * scale), 1)
    guard let scaled = draw(crop, width: w, height: h, margin: 0) else { return nil }
    crop = scaled
    if blackAndWhite, let bw = binarize(crop) { crop = bw }
    let m = max(w, h)
    guard let page = draw(crop, width: w, height: h, margin: m) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
      try VNImageRequestHandler(cgImage: page, options: [:]).perform([request])
    } catch {
      return nil
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
  }

  /// `image` drawn at `width`×`height` on a white page with `margin` px.
  private static func draw(_ image: CGImage, width: Int, height: Int, margin: Int) -> CGImage? {
    guard
      let ctx = CGContext(
        data: nil, width: width + 2 * margin, height: height + 2 * margin,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width + 2 * margin, height: height + 2 * margin))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: margin, y: margin, width: width, height: height))
    return ctx.makeImage()
  }

  /// Grayscale + Otsu threshold: dark ink on white.
  static func binarize(_ image: CGImage) -> CGImage? {
    let w = image.width
    let h = image.height
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h)
    var hist = [Int](repeating: 0, count: 256)
    for i in 0..<(w * h) { hist[Int(px[i])] += 1 }
    let total = w * h
    var sum = 0.0
    for t in 0..<256 { sum += Double(t * hist[t]) }
    var sumB = 0.0
    var wB = 0
    var best = 0.0
    var threshold = 128
    for t in 0..<256 {
      wB += hist[t]
      if wB == 0 { continue }
      let wF = total - wB
      if wF == 0 { break }
      sumB += Double(t * hist[t])
      let mB = sumB / Double(wB)
      let mF = (sum - sumB) / Double(wF)
      let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
      if between > best {
        best = between
        threshold = t
      }
    }
    for i in 0..<(w * h) { px[i] = Int(px[i]) <= threshold ? 0 : 255 }
    return ctx.makeImage()
  }
}

/// What the section passes tried and read, for the session log.
final class PassLog {
  private(set) var lines: [String] = []
  func add(_ line: String) { lines.append(line) }
}
