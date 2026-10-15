import AVFoundation
import Flutter
import UIKit

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
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
