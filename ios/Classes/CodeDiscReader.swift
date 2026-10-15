import CoreGraphics
import Foundation
import Vision

/// Section 1 pass: the circled service code (mirrors `CodeDiscReader.kt`).
///
/// Latin OCR reads the ring as a letter ("D-0123456") and misses the digit.
/// Reading only the inner disc returns it. Crops are scanned left to right
/// through the zone left of the number; the sweep is repeated in black and
/// white if nothing reads.
enum CodeDiscReader {
  private static let discSize: CGFloat = 180

  /// Returns "1"..."5", or nil. `image` is only called when a pass is needed
  /// and must return the upright image the observations refer to.
  static func read(
    _ observations: [VNRecognizedTextObservation],
    log: PassLog? = nil,
    image: () -> CGImage?
  ) -> String? {
    guard let cg = image(),
      let anchor = CropOcr.numberAnchor(
        observations, width: CGFloat(cg.width), height: CGFloat(cg.height))
    else {
      log?.add("code: no number anchor")
      return nil
    }
    log?.add("code: anchor digit=\(anchor.first) numberHeight=\(anchor.height) image=\(cg.width)x\(cg.height)")
    let h = anchor.height
    let half = h * 0.2
    let cy = (anchor.top + anchor.bottom) / 2
    for blackAndWhite in [false, true] {
      var cx = max(half, anchor.first.minX - 3.5 * h)
      let end = anchor.first.minX - 0.4 * h
      while cx <= end {
        let area = CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
        let read = CropOcr.read(cg, area: area, size: discSize, blackAndWhite: blackAndWhite)
        let code = digitOf(read)
        log?.add("code: crop=\(area) bw=\(blackAndWhite) read='\(read ?? "nil")' -> \(code ?? "nil")")
        if let code = code { return code }
        cx += h * 0.15
      }
    }
    return nil
  }

  // Ring fragments read as brackets / O are dropped; glyphs commonly read
  // for the code digit are mapped.
  private static let ringNoise: Set<Character> = [
    "(", ")", "[", "]", "{", "}", "O", "o", "C", "c", "0", ".", ",", "-",
  ]
  private static let asDigit: [Character: Character] = [
    "I": "1", "l": "1", "|": "1", "i": "1", "Z": "2", "z": "2", "S": "5", "s": "5",
  ]

  static func digitOf(_ text: String?) -> String? {
    guard let text = text else { return nil }
    let chars = text.filter { !$0.isWhitespace && !ringNoise.contains($0) }
      .map { asDigit[$0] ?? $0 }
    guard let first = chars.first, chars.allSatisfy({ $0 == first }),
      ("1"..."5").contains(String(first))
    else { return nil }
    return String(first)
  }
}
