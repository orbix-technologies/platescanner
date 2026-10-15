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
    default:
      result(FlutterMethodNotImplemented)
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
      let codeHint = CodeDiscReader.read(request.results ?? []) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Apply EXIF orientation so pixels match Vision's upright boxes.
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      }
      var payload: [String: Any] = ["lines": lines]
      if let codeHint = codeHint { payload["codeHint"] = codeHint }
      DispatchQueue.main.async { result(payload) }
    }
  }
}
