import AVFoundation
import Flutter
import ImageIO
import UIKit
import Vision

/// Registers the availability channel and the `et_plate_reader/scanner` view.
public class EtPlateReaderPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "et_plate_reader/availability",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(EtPlateReaderPlugin(), channel: channel)
    registrar.register(
      PlateScannerViewFactory(messenger: registrar.messenger()),
      withId: PlateScannerViewFactory.viewType
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkAvailability":
      // Camera-free: only asks whether a back camera exists. Vision's text
      // recogniser ships with iOS 13+, so no model download is needed.
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      result(["status": camera == nil ? "noCamera" : "supported"])
    case "recognizeImage":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      recognizeImage(URL(fileURLWithPath: path), result: result)
    case "readCrops":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let crops = args["crops"] as? [[String: Double]]
      else {
        result(FlutterError(code: "bad_args", message: "path and crops are required", details: nil))
        return
      }
      let size = CGFloat(args["size"] as? Double ?? 160)
      let url = URL(fileURLWithPath: path)
      DispatchQueue.global(qos: .userInitiated).async {
        guard let image = Self.loadUpright(url) else {
          DispatchQueue.main.async {
            result(FlutterError(code: "ocr_failed", message: "Unsupported image", details: nil))
          }
          return
        }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        // One [colour, bw, clean] text triple per crop.
        let reads: [[Any]] = crops.map { c in
          let area = CGRect(
            x: (c["left"] ?? 0) * w, y: (c["top"] ?? 0) * h,
            width: ((c["right"] ?? 0) - (c["left"] ?? 0)) * w,
            height: ((c["bottom"] ?? 0) - (c["top"] ?? 0)) * h)
          return CropOcr.Mode.allCases.map { mode -> Any in
            CropOcr.read(image, area: area, size: size, mode: mode) ?? NSNull()
          }
        }
        DispatchQueue.main.async { result(reads) }
      }
    case "recognizeArea":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let l = args["left"] as? Double, let t = args["top"] as? Double,
        let r = args["right"] as? Double, let b = args["bottom"] as? Double
      else {
        result(FlutterError(code: "bad_args", message: "path and area are required", details: nil))
        return
      }
      recognizeArea(
        URL(fileURLWithPath: path),
        area: CGRect(x: l, y: t, width: r - l, height: b - t),
        sectionPasses: args["sectionPasses"] as? Bool ?? true,
        result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Image with EXIF orientation applied, so pixels match Vision's boxes.
  private static func loadUpright(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Step 3: every character inside a normalized `area` (top-left origin) of
  /// a still. The crop is upscaled and padded with white; boxes come back
  /// normalized to the area (mirrors recognizeArea in the Android plugin).
  private func recognizeArea(
    _ url: URL, area: CGRect, sectionPasses: Bool, result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      func fail(_ message: String) {
        DispatchQueue.main.async {
          result(FlutterError(code: "ocr_failed", message: message, details: nil))
        }
      }
      guard let image = Self.loadUpright(url) else { return fail("Unsupported image") }
      let iw = CGFloat(image.width)
      let ih = CGFloat(image.height)
      let src = CGRect(
        x: area.minX * iw, y: area.minY * ih, width: area.width * iw, height: area.height * ih
      ).integral.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
      guard src.width >= 8, src.height >= 8, let crop = image.cropping(to: src) else {
        return fail("Plate area is too small")
      }
      let scale = min(max(480 / src.height, 1), 4)
      let w = Int(src.width * scale)
      let h = Int(src.height * scale)
      let pad = Int(CGFloat(h) * 0.15)
      let pw = w + 2 * pad
      let ph = h + 2 * pad
      guard
        let ctx = CGContext(
          data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return fail("Out of memory") }
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
      ctx.interpolationQuality = .high
      ctx.draw(crop, in: CGRect(x: pad, y: pad, width: w, height: h))
      guard let page = ctx.makeImage() else { return fail("Out of memory") }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      do {
        try VNImageRequestHandler(cgImage: page, options: [:]).perform([request])
      } catch {
        return fail(error.localizedDescription)
      }
      let observations = request.results ?? []

      // Vision box (normalized to the page, bottom-left origin) → area.
      func norm(_ b: CGRect) -> [String: Any] {
        [
          "left": Double((b.minX * CGFloat(pw) - CGFloat(pad)) / CGFloat(w)),
          "top": Double(((1 - b.maxY) * CGFloat(ph) - CGFloat(pad)) / CGFloat(h)),
          "right": Double((b.maxX * CGFloat(pw) - CGFloat(pad)) / CGFloat(w)),
          "bottom": Double(((1 - b.minY) * CGFloat(ph) - CGFloat(pad)) / CGFloat(h)),
        ]
      }
      var elements: [[String: Any]] = []
      for obs in observations {
        guard let best = obs.topCandidates(1).first else { continue }
        let text = best.string
        var symbols: [[String: Any]] = []
        var i = text.startIndex
        while i < text.endIndex {
          let next = text.index(after: i)
          if !text[i].isWhitespace,
            let box = try? best.boundingBox(for: i..<next)?.boundingBox
          {
            var symbol = norm(box)
            symbol["text"] = String(text[i])
            symbols.append(symbol)
          }
          i = next
        }
        var element = norm(obs.boundingBox)
        element["text"] = text
        element["confidence"] = Double(best.confidence)
        element["symbols"] = symbols
        elements.append(element)
      }
      var payload: [String: Any] = ["elements": elements]
      // What each section pass tried and read, for the session log.
      let log = PassLog()
      log.add("area: src=\(src) image=\(image.width)x\(image.height) scale=\(scale) page=\(pw)x\(ph) pad=\(pad)")
      // Circle / stacked-letter passes: only without segmentation.
      if sectionPasses, let code = CodeDiscReader.read(observations, log: log, image: { page }) {
        payload["codeHint"] = code
        payload["codeVotes"] = CodeDiscReader.lastVotes
      }
      // Pixel rect on the page (top-left origin) → area.
      func normPx(_ r: CGRect) -> [String: Any] {
        [
          "left": Double((r.minX - CGFloat(pad)) / CGFloat(w)),
          "top": Double((r.minY - CGFloat(pad)) / CGFloat(h)),
          "right": Double((r.maxX - CGFloat(pad)) / CGFloat(w)),
          "bottom": Double((r.maxY - CGFloat(pad)) / CGFloat(h)),
        ]
      }
      payload["regionColumns"] = (sectionPasses
        ? RegionStackReader.read(observations, image: page, log: log) : []).map {
        col -> [String: Any] in
        var column = normPx(col.box)
        column["letters"] = col.letters
        column["source"] = col.source
        column["topHalf"] = normPx(col.top)
        column["bottomHalf"] = normPx(col.bottom)
        return column
      }
      // Section 1 fallback: the number's ink colour gives the code.
      if let a = CropOcr.numberAnchor(
        observations, width: CGFloat(page.width), height: CGFloat(page.height))
      {
        let numberBox = CGRect(
          x: a.first.minX, y: a.top, width: a.last.maxX - a.first.minX, height: a.height)
        if let rgb = CropOcr.inkColor(page, area: numberBox) {
          payload["inkColor"] = rgb
          log.add("ink: number=\(numberBox) rgb=\(rgb)")
        }
        if let rgb = CropOcr.paperColor(page, area: numberBox) {
          payload["paperColor"] = rgb
          log.add("paper: rgb=\(rgb)")
        }
      }
      payload["debug"] = log.lines
      DispatchQueue.main.async { result(payload) }
    }
  }

  /// Still-image OCR with the same payload as a camera frame.
  private func recognizeImage(_ url: URL, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      do {
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil))
        }
        return
      }
      let lines: [[String: Any]] = (request.results ?? []).compactMap { obs in
        guard let best = obs.topCandidates(1).first else { return nil }
        let box = obs.boundingBox
        return [
          "text": best.string,
          "confidence": Double(best.confidence),
          "left": Double(box.minX),
          "top": Double(1 - box.maxY),
          "right": Double(box.maxX),
          "bottom": Double(1 - box.minY),
        ]
      }
      let codeHint = CodeDiscReader.read(request.results ?? []) { Self.loadUpright(url) }
      var payload: [String: Any] = ["lines": lines]
      if let codeHint = codeHint { payload["codeHint"] = codeHint }
      DispatchQueue.main.async { result(payload) }
    }
  }
}
