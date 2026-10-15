import CoreGraphics
import Foundation
import Vision

/// Section 4 pass: the Latin region, two letters stacked at the right end
/// (mirrors `RegionStackReader.kt`). Each candidate column is cut into a top
/// and a bottom half and each half is read alone as one letter.
enum RegionStackReader {
  private static let halfSize: CGFloat = 160
  private static let noise: Set<Character> = [".", ",", "-", "_", "'", "\"", ":", ";", "|"]
  private static let asLetter: [Character: Character] = [
    "4": "A", "0": "O", "1": "I", "5": "S", "8": "B", "6": "G", "2": "Z",
  ]

  /// Pixel rects (top-left origin) of the column and its halves.
  struct Column {
    let letters: String
    let source: String
    let box: CGRect
    let top: CGRect
    let bottom: CGRect
  }

  /// Every candidate column that read as two letters, in the order tried.
  static func read(
    _ observations: [VNRecognizedTextObservation], image: CGImage, log: PassLog? = nil
  ) -> [Column] {
    let width = CGFloat(image.width)
    guard
      let anchor = CropOcr.numberAnchor(
        observations, width: width, height: CGFloat(image.height))
    else {
      log?.add("region: no number anchor")
      return []
    }
    let h = anchor.height
    let pad = h * 0.05
    let last = anchor.last

    var candidates: [(String, CGFloat, CGFloat)] = []
    let trailing = anchor.rects[anchor.end...].filter { $0 != .zero }
    if !trailing.isEmpty {
      candidates.append(
        ("trailing", trailing.map { $0.minX }.min()! - pad, trailing.map { $0.maxX }.max()! + pad))
    }
    // Latin stack: 0.05–1.1 digit pitch right of the number (measured on
    // real plates); wider reaches stray text such as watermarks.
    let p = (last.maxX - anchor.first.minX) / CGFloat(anchor.end - anchor.start)
    let zoneRight = min(width, last.maxX + p * 1.1)
    if zoneRight - last.maxX >= h / 4 {
      candidates.append(("zone", last.maxX + pad, zoneRight))
    }
    candidates.append(("lastDigit", last.minX - pad, last.maxX + pad))

    let mid = anchor.top + h / 2
    var found: [Column] = []
    for (source, x0, x1) in candidates {
      let top = CGRect(x: x0, y: anchor.top - 2 * pad, width: x1 - x0, height: mid - anchor.top + 2 * pad)
      let bottom = CGRect(x: x0, y: mid, width: x1 - x0, height: anchor.bottom + 2 * pad - mid)
      var a = letter(image, top, log, "\(source)/top")
      var b = letter(image, bottom, log, "\(source)/bottom")
      if a == nil || b == nil, let pair = word(image, top, bottom, log, source) {
        // Lone letters read poorly; side by side they read as a word.
        a = pair[0]
        b = pair[1]
      }
      guard let a = a, let b = b else { continue }
      found.append(
        Column(
          letters: "\(a)\(b)", source: source,
          box: CGRect(x: x0, y: anchor.top, width: x1 - x0, height: h),
          top: top, bottom: bottom))
    }
    return found
  }

  private static func lettersOf(_ text: String?) -> [Character] {
    (text ?? "").filter { !$0.isWhitespace && !noise.contains($0) }
      .map { c -> Character in asLetter[c] ?? c.uppercased().first ?? c }
  }

  /// One letter read as photographed, in black and white, and with the
  /// border erased; the majority letter wins, a tie gives none.
  private static func letter(
    _ image: CGImage, _ area: CGRect, _ log: PassLog?, _ label: String
  ) -> Character? {
    var counts: [Character: Int] = [:]
    for mode in CropOcr.Mode.allCases {
      let text = CropOcr.read(image, area: area, size: halfSize, mode: mode)
      let chars = lettersOf(text)
      var letter: Character?
      if chars.count == 1, let c = chars.first, ("A"..."Z").contains(String(c)) { letter = c }
      log?.add(
        "region: \(label) crop=\(area) mode=\(mode) read='\(text ?? "nil")' -> \(letter.map(String.init) ?? "nil")")
      if let letter = letter { counts[letter, default: 0] += 1 }
    }
    guard let top = counts.values.max() else { return nil }
    let winners = counts.filter { $0.value == top }.map { $0.key }
    if winners.count > 1 {
      log?.add("region: \(label) reads disagree \(counts) -> none")
      return nil
    }
    return winners.first
  }

  /// Both halves cleaned and read side by side as one two-letter word.
  private static func word(
    _ image: CGImage, _ top: CGRect, _ bottom: CGRect, _ log: PassLog?, _ source: String
  ) -> [Character]? {
    guard let a = CropOcr.prepare(image, area: top, size: halfSize, mode: .clean),
      let b = CropOcr.prepare(image, area: bottom, size: halfSize, mode: .clean)
    else { return nil }
    let text = CropOcr.ocr([a, b])
    let chars = lettersOf(text)
    let ok = chars.count == 2 && chars.allSatisfy { ("A"..."Z").contains(String($0)) }
    log?.add("region: \(source)/word read='\(text ?? "nil")' -> \(ok ? String(chars) : "nil")")
    return ok ? chars : nil
  }
}
