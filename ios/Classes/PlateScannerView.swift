import AVFoundation
import CoreImage
import Flutter
import UIKit
import Vision

/// Platform view wrapper: owns the channel and the scanner view.
class PlateScannerPlatformView: NSObject, FlutterPlatformView {
  private let scanner: PlateScannerView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "\(PlateScannerViewFactory.viewType)_\(viewId)",
      binaryMessenger: messenger
    )
    scanner = PlateScannerView(frame: frame, channel: channel)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.scanner.handle(call, result: result)
    }
  }

  func view() -> UIView { scanner }

  deinit {
    channel.setMethodCallHandler(nil)
    scanner.shutdown()
  }
}

/// AVFoundation preview + Vision text recognition.
///
/// Frames are analysed one at a time on `videoQueue`; only recognised lines,
/// normalized to the visible (aspect-filled) preview area, cross the channel.
class PlateScannerView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let channel: FlutterMethodChannel
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "et_plate_reader.session")
  private let videoQueue = DispatchQueue(label: "et_plate_reader.video")
  private let previewLayer: AVCaptureVideoPreviewLayer
  private var device: AVCaptureDevice?
  private let lock = NSLock()
  private var analyzing = false
  private var busy = false
  private var viewAspect: CGFloat = 9.0 / 16.0
  private var stopped = false
  private var pendingCapture: FlutterResult?

  init(frame: CGRect, channel: FlutterMethodChannel) {
    self.channel = channel
    previewLayer = AVCaptureVideoPreviewLayer(session: session)
    super.init(frame: frame)
    backgroundColor = .black
    previewLayer.videoGravity = .resizeAspectFill
    layer.addSublayer(previewLayer)
    sessionQueue.async { [weak self] in self?.configure() }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer.frame = bounds
    if bounds.height > 0 {
      lock.lock()
      viewAspect = bounds.width / bounds.height
      lock.unlock()
    }
  }

  private func configure() {
    session.beginConfiguration()
    session.sessionPreset = .hd1280x720
    guard
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    else {
      session.commitConfiguration()
      sendError("Camera could not be opened")
      return
    }
    session.addInput(input)
    device = camera

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    output.setSampleBufferDelegate(self, queue: videoQueue)
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    session.startRunning()
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onReady", arguments: nil)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      setAnalyzing(true)
      result(nil)
    case "pause":
      setAnalyzing(false)
      result(nil)
    case "captureFrame":
      lock.lock()
      let busy = pendingCapture != nil
      if !busy { pendingCapture = result }
      lock.unlock()
      if busy {
        result(FlutterError(code: "busy", message: "Capture already in progress", details: nil))
      }
    case "setTorch":
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      result(setTorch(on))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setAnalyzing(_ value: Bool) {
    lock.lock()
    analyzing = value
    lock.unlock()
  }

  private func setTorch(_ on: Bool) -> Bool {
    guard let device = device, device.hasTorch else { return false }
    do {
      try device.lockForConfiguration()
      device.torchMode = on ? .on : .off
      device.unlockForConfiguration()
      return on
    } catch {
      return false
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.lock()
    let capture = pendingCapture
    pendingCapture = nil
    let shouldRun = analyzing && !busy && !stopped
    if shouldRun { busy = true }
    let aspect = viewAspect
    lock.unlock()

    // Back camera in portrait: buffer is landscape, `.right` makes it upright.
    let uprightWidth = CGFloat(CVPixelBufferGetHeight(pixels))
    let uprightHeight = CGFloat(CVPixelBufferGetWidth(pixels))
    let visible = Self.visibleRect(imageAspect: uprightWidth / uprightHeight, viewAspect: aspect)

    if let capture = capture {
      saveStill(pixels, visible: visible, result: capture)
    }
    guard shouldRun else { return }

    let request = VNRecognizeTextRequest { [weak self] request, _ in
      self?.deliver(request.results as? [VNRecognizedTextObservation] ?? [], visible: visible)
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.regionOfInterest = visible.flippedForVision

    let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right, options: [:])
    do {
      try handler.perform([request])
    } catch {
      finishFrame()
    }
  }

  private static let ciContext = CIContext()

  private func deliver(_ observations: [VNRecognizedTextObservation], visible: CGRect) {
    var lines: [[String: Any]] = []
    for obs in observations {
      guard let best = obs.topCandidates(1).first else { continue }
      // Vision: normalized, origin bottom-left → top-left, then into visible area.
      let box = obs.boundingBox
      let top = 1 - box.maxY
      let bottom = 1 - box.minY
      lines.append([
        "text": best.string,
        "confidence": Double(best.confidence),
        "left": Double((box.minX - visible.minX) / visible.width),
        "top": Double((top - visible.minY) / visible.height),
        "right": Double((box.maxX - visible.minX) / visible.width),
        "bottom": Double((bottom - visible.minY) / visible.height),
      ])
    }
    finishFrame()
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isStopped else { return }
      self.channel.invokeMethod("onFrame", arguments: ["lines": lines])
    }
  }

  /// Saves this frame, cropped to the visible preview, as a JPEG still.
  private func saveStill(_ pixels: CVPixelBuffer, visible: CGRect, result: @escaping FlutterResult) {
    let upright = CIImage(cvPixelBuffer: pixels).oriented(.right)
    let e = upright.extent
    // `visible` has a top-left origin; Core Image's is bottom-left.
    let rect = CGRect(
      x: e.minX + visible.minX * e.width,
      y: e.minY + (1 - visible.maxY) * e.height,
      width: visible.width * e.width,
      height: visible.height * e.height)
    let cropped = upright.cropped(to: rect)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("et_plate_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
    guard let cg = Self.ciContext.createCGImage(cropped, from: cropped.extent),
      let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92),
      (try? data.write(to: url)) != nil
    else {
      DispatchQueue.main.async {
        result(FlutterError(code: "capture_failed", message: "Could not save the frame", details: nil))
      }
      return
    }
    DispatchQueue.main.async {
      result(["path": url.path, "width": cg.width, "height": cg.height])
    }
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func finishFrame() {
    lock.lock()
    busy = false
    lock.unlock()
  }

  private func sendError(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onError", arguments: ["message": message])
    }
  }

  func shutdown() {
    lock.lock()
    stopped = true
    analyzing = false
    lock.unlock()
    let session = self.session
    sessionQueue.async { session.stopRunning() }
  }

  /// Part of the upright image shown by an aspect-fill preview (top-left origin).
  static func visibleRect(imageAspect: CGFloat, viewAspect: CGFloat) -> CGRect {
    if imageAspect > viewAspect {
      let w = viewAspect / imageAspect
      return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }
    let h = imageAspect / viewAspect
    return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
  }
}

private extension CGRect {
  /// Same rect with a bottom-left origin, as Vision expects.
  var flippedForVision: CGRect {
    CGRect(x: minX, y: 1 - maxY, width: width, height: height)
  }
}
