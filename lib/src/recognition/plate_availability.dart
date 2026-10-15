import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';

/// Result of a camera / recogniser preflight check.
enum PlateReaderAvailabilityStatus {
  /// Device can attempt plate reading.
  supported,

  /// Device or platform cannot run this package.
  unsupported,

  /// Camera is present but the recognition model is not available yet
  /// (e.g. ML Kit still downloading on Android).
  modelMissing,

  /// Availability could not be determined.
  unknown,
}

/// Camera-free availability snapshot for host UI gating.
class PlateReaderAvailability {
  /// Creates a snapshot.
  const PlateReaderAvailability({required this.status, this.message});

  /// Overall status.
  final PlateReaderAvailabilityStatus status;

  /// Short host-facing hint when not [isSupported].
  final String? message;

  /// True when [status] is [PlateReaderAvailabilityStatus.supported].
  bool get isSupported => status == PlateReaderAvailabilityStatus.supported;

  /// Supported.
  static const supported = PlateReaderAvailability(
    status: PlateReaderAvailabilityStatus.supported,
  );

  /// Not Android / iOS.
  static const unsupportedPlatform = PlateReaderAvailability(
    status: PlateReaderAvailabilityStatus.unsupported,
    message: 'Plate reading is only available on Android and iOS.',
  );

  /// No usable camera.
  static const unsupportedDevice = PlateReaderAvailability(
    status: PlateReaderAvailabilityStatus.unsupported,
    message: 'This device has no camera that can read plates.',
  );

  /// Model not available yet.
  static const modelMissing = PlateReaderAvailability(
    status: PlateReaderAvailabilityStatus.modelMissing,
    message: 'The text recognition model is not ready yet. Try again shortly.',
  );

  /// Unknown.
  static const unknown = PlateReaderAvailability(
    status: PlateReaderAvailabilityStatus.unknown,
    message: 'Plate reader availability could not be determined.',
  );
}

/// Public façade for package-level helpers (no controller / camera required).
class PlateReader {
  PlateReader._();

  /// Channel answered by both native plugins.
  static const availabilityChannel = MethodChannel(
    'et_plate_reader/availability',
  );

  /// Camera-free preflight: whether this device can read plates.
  ///
  /// Prefer this before navigating to [PlateScannerView]. Still handle
  /// `onError` after init (permission, camera open).
  static Future<PlateReaderAvailability> checkAvailability() async {
    if (kIsWeb) return PlateReaderAvailability.unsupportedPlatform;
    if (!Platform.isAndroid && !Platform.isIOS) {
      return PlateReaderAvailability.unsupportedPlatform;
    }
    try {
      final result = await availabilityChannel
          .invokeMapMethod<String, Object?>('checkAvailability');
      return fromNative(result);
    } on MissingPluginException {
      return PlateReaderAvailability.unsupportedDevice;
    } on PlatformException {
      return PlateReaderAvailability.unknown;
    }
  }

  /// Convenience: `true` when [checkAvailability] reports supported.
  static Future<bool> isSupported() async =>
      (await checkAvailability()).isSupported;

  /// Raw OCR of a still image file (JPEG / PNG) — no camera needed.
  static Future<OcrFrame> recognizeImage(String path) async {
    try {
      final result = await availabilityChannel
          .invokeMapMethod<String, Object?>('recognizeImage', {'path': path});
      return OcrFrame.fromMap(result ?? const {});
    } on PlatformException catch (e) {
      throw PlateReaderException(
        PlateReaderErrorCode.channelError,
        e.message ?? 'Image could not be read',
        cause: e,
      );
    }
  }

  /// Reads a plate from a still image (e.g. a gallery photo).
  ///
  /// When [region] is given, only lines entirely inside it (normalized image
  /// coordinates) are parsed.
  static Future<PlateCandidate> readImage(
    String path, {
    EthiopianPlateParser parser = const EthiopianPlateParser(),
    NormalizedRect? region,
  }) async {
    final frame = await recognizeImage(path);
    final lines = region == null
        ? frame.lines
        : frame.lines.where((l) => region.contains(l.box)).toList();
    return parser.parse(lines, codeHint: frame.codeHint);
  }

  /// Maps the native `{status}` payload (exposed for tests).
  static PlateReaderAvailability fromNative(Map<String, Object?>? result) {
    switch (result?['status']) {
      case 'supported':
        return PlateReaderAvailability.supported;
      case 'noCamera':
        return PlateReaderAvailability.unsupportedDevice;
      case 'modelMissing':
        return PlateReaderAvailability.modelMissing;
      default:
        return PlateReaderAvailability.unknown;
    }
  }
}
