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

  /// How a crop is prepared before OCR.
  enum Mode: CaseIterable {
    /// As photographed.
    case colour
    /// Grayscale + Otsu threshold.
    case bw
    /// Black and white with long straight lines (plate border) erased.
    case clean
  }

  /// OCR of `area` (pixels, top-left origin) of `image` alone: scaled so its
  /// height is `size` px, centred on a white page.
  static func read(_ image: CGImage, area: CGRect, size: CGFloat, blackAndWhite: Bool) -> String? {
    read(image, area: area, size: size, mode: blackAndWhite ? .bw : .colour)
  }

  static func read(_ image: CGImage, area: CGRect, size: CGFloat, mode: Mode) -> String? {
    guard let crop = prepare(image, area: area, size: size, mode: mode) else { return nil }
    return ocr([crop])
  }

  /// `area` of `image` scaled to `size` px tall and prepared per `mode`.
  static func prepare(_ image: CGImage, area: CGRect, size: CGFloat, mode: Mode) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let src = area.integral.intersection(bounds)
    guard src.width >= 6, src.height >= 6, let raw = image.cropping(to: src) else { return nil }
    let scale = min(max(size / src.height, 0.5), 5)
    let w = max(Int(src.width * scale), 1)
    let h = max(Int(src.height * scale), 1)
    guard var crop = draw(raw, width: w, height: h, margin: 0) else { return nil }
    if mode != .colour, let bw = binarize(crop) { crop = bw }
    if mode == .clean, let clean = stripLines(crop) { crop = clean }
    return crop
  }

  /// OCR of `crops` laid side by side on one white page, so several single
  /// letters read as one word.
  static func ocr(_ crops: [CGImage]) -> String? {
    guard !crops.isEmpty else { return nil }
    let m = crops.map { max($0.width, $0.height) }.max()!
    let width = crops.map { $0.width }.reduce(0, +) + m * (crops.count + 1)
    let height = crops.map { $0.height }.max()! + 2 * m
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = m
    for c in crops {
      ctx.draw(c, in: CGRect(x: x, y: m, width: c.width, height: c.height))
      x += c.width + m
    }
    guard let page = ctx.makeImage() else { return nil }
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

  /// Erases rows / columns that are mostly ink (the plate border).
  static func stripLines(_ image: CGImage) -> CGImage? {
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
    for y in 0..<h {
      var ink = 0
      for x in 0..<w where px[y * w + x] < 128 { ink += 1 }
      if Double(ink) > Double(w) * 0.6 { for x in 0..<w { px[y * w + x] = 255 } }
    }
    for x in 0..<w {
      var ink = 0
      for y in 0..<h where px[y * w + x] < 128 { ink += 1 }
      if Double(ink) > Double(h) * 0.6 { for y in 0..<h { px[y * w + x] = 255 } }
    }
    return ctx.makeImage()
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

  /// Average colour of the ink (pixels darker than the Otsu threshold) in
  /// `area` (pixels, top-left origin), as [r, g, b], or nil. The number's
  /// colour identifies the category (code 1 red … 5 orange).
  static func inkColor(_ image: CGImage, area: CGRect) -> [Int]? {
    meanColor(image, area: area, dark: true)
  }

  /// Average colour of the plate background (pixels lighter than the Otsu
  /// threshold); a yellow background marks a police plate.
  static func paperColor(_ image: CGImage, area: CGRect) -> [Int]? {
    meanColor(image, area: area, dark: false)
  }

  private static func meanColor(_ image: CGImage, area: CGRect, dark: Bool) -> [Int]? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let r = area.integral.intersection(bounds)
    guard r.width >= 4, r.height >= 4, let crop = image.cropping(to: r) else { return nil }
    let w = crop.width
    let h = crop.height
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var lum = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      lum[i] = (299 * Int(px[i * 4]) + 587 * Int(px[i * 4 + 1]) + 114 * Int(px[i * 4 + 2])) / 1000
    }
    let t = otsu(lum)
    var n = 0
    var sr = 0
    var sg = 0
    var sb = 0
    for i in 0..<(w * h) where (lum[i] <= t) == dark {
      sr += Int(px[i * 4])
      sg += Int(px[i * 4 + 1])
      sb += Int(px[i * 4 + 2])
      n += 1
    }
    return n == 0 ? nil : [sr / n, sg / n, sb / n]
  }

  static func otsu(_ lum: [Int]) -> Int {
    var hist = [Int](repeating: 0, count: 256)
    for l in lum { hist[l] += 1 }
    let total = lum.count
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
    return threshold
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
