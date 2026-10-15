import CoreGraphics
import Foundation
import Vision

/// Second OCR pass for the circled service code on new-format plates.
///
/// Latin OCR reads the ring as a letter ("D-0123456") and misses the digit.
/// Reading only the inner disc — ring cropped away, padded with white,
/// upscaled — returns the digit. Mirrors `CodeDiscReader.kt`.
enum CodeDiscReader {
  private static let serialRun = try! NSRegularExpression(pattern: "\\d{5,}")
  private static let visibleCode = try! NSRegularExpression(
    pattern: "(^|[^0-9])[1-5]([^0-9]|$)|[\\u2460-\\u2464]")

  // Disc centre offsets from the line's left edge, × line height: a fine
  // scan near the edge, then further left (see CodeDiscReader.kt).
  private static let centreOffsets: [CGFloat] = [
    0.1, 0.2, 0.0, 0.3, -0.1, 0.4, -0.2, -1.45, -1.1, -0.8,
  ]

  /// Returns "1"..."5", or nil. `image` is only called when a pass is needed
  /// and must return the upright image the observations refer to.
  static func read(
    _ observations: [VNRecognizedTextObservation],
    image: () -> CGImage?
  ) -> String? {
    var best: (VNRecognizedTextObservation, String)?
    for obs in observations {
      guard let text = obs.topCandidates(1).first?.string, matchStart(serialRun, text) != nil else {
        continue
      }
      if best == nil || obs.boundingBox.height > best!.0.boundingBox.height {
        best = (obs, text)
      }
    }
    guard let pick = best, let start = matchStart(serialRun, pick.1) else { return nil }
    let line = pick.0
    let text = pick.1
    let prefix = String(text.prefix(start))
    if matchStart(visibleCode, prefix) != nil { return nil }
    guard let cg = image() else { return nil }

    let w = CGFloat(cg.width)
    let h = CGFloat(cg.height)
    let box = line.boundingBox
    let left = box.minX * w
    let lineHeight = box.height * h
    let cy = (1 - box.midY) * h
    let half = lineHeight * 0.17
    for offset in centreOffsets {
      let cx = left + offset * lineHeight
      let area = CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
      if let digit = readCrop(cg, area: area) { return digit }
    }
    return nil
  }

  private static func matchStart(_ regex: NSRegularExpression, _ text: String) -> Int? {
    let range = NSRange(text.startIndex..., in: text)
    guard let m = regex.firstMatch(in: text, range: range),
      let r = Range(m.range, in: text)
    else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
  }

  private static func readCrop(_ image: CGImage, area: CGRect) -> String? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let src = area.intersection(bounds).integral
    guard src.width >= 8, src.height >= 8, let crop = image.cropping(to: src) else { return nil }

    // Inner disc scaled to ~180 px (a fixed ×3 blurs crops that were
    // already upscaled), centred on a white page 3× larger again.
    let scale = min(max(180 / src.width, 0.5), 4)
    let cw = Int(src.width * scale)
    let ch = Int(src.height * scale)
    guard
      let ctx = CGContext(
        data: nil, width: cw * 3, height: ch * 3, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cw * 3, height: ch * 3))
    ctx.interpolationQuality = .high
    ctx.draw(crop, in: CGRect(x: cw, y: ch, width: cw, height: ch))
    guard let page = ctx.makeImage() else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
      try VNImageRequestHandler(cgImage: page, options: [:]).perform([request])
    } catch {
      return nil
    }
    let text = (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .joined()
    return digitOf(text)
  }

  // Ring fragments read as brackets / O are dropped; glyphs commonly read
  // for the code digit are mapped (mirrors CodeDiscReader.kt).
  private static let ringNoise: Set<Character> = [
    "(", ")", "[", "]", "{", "}", "O", "o", "C", "c", "0", ".", ",", "-",
  ]
  private static let asDigit: [Character: Character] = [
    "I": "1", "l": "1", "|": "1", "i": "1", "Z": "2", "z": "2", "S": "5", "s": "5",
  ]

  static func digitOf(_ text: String) -> String? {
    let chars = text.filter { !$0.isWhitespace && !ringNoise.contains($0) }
      .map { asDigit[$0] ?? $0 }
    guard let first = chars.first, chars.allSatisfy({ $0 == first }),
      ("1"..."5").contains(String(first))
    else { return nil }
    return String(first)
  }
}
