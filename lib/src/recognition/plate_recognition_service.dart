import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import 'channel_plate_recognition_service.dart';

/// Abstraction over the native camera + recognition pipeline.
///
/// Hosts normally use [PlateReaderController] rather than calling this
/// directly. Tests inject a fake (see `test/fake_plate_service.dart`).
abstract class PlateRecognitionService {
  /// Prepare the backend (no-op on some backends).
  Future<void> initialize();

  /// One result per analysed camera frame while running.
  Stream<OcrFrame> get frameStream;

  /// Native / session errors for host UI.
  Stream<String> get platformErrorStream;

  /// Wait until the platform preview can accept commands.
  Future<void> ensureReady({Duration timeout = const Duration(seconds: 5)});

  /// Start (or resume) frame analysis.
  Future<void> start();

  /// Stop frame analysis; the preview keeps running.
  Future<void> pause();

  /// Save the next camera frame (exactly the visible preview) as a still.
  Future<CapturedFrame> captureFrame();

  /// Read every character inside [area] (normalized) of a captured still.
  Future<AreaOcr> recognizeArea(String path, NormalizedRect area);

  /// Turn the torch on or off. Returns the resulting state.
  Future<bool> setTorch(bool on);

  /// Tear down streams and native resources.
  Future<void> dispose();

  /// Whether this device can run the backend.
  Future<bool> isSupported();
}

/// Factory to create the platform [PlateRecognitionService].
class PlateRecognitionServiceFactory {
  /// Returns the channel-backed service, or throws on unsupported platforms.
  static PlateRecognitionService create() {
    if (kIsWeb) {
      throw UnsupportedError('Plate reading is not supported on web');
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return ChannelPlateRecognitionService();
    }
    throw UnsupportedError(
        'Plate reading is only supported on Android and iOS');
  }
}
