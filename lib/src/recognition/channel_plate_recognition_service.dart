import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import 'plate_availability.dart';
import 'plate_recognition_service.dart';

/// Android / iOS service talking to the native `et_plate_reader/scanner` view.
///
/// Both natives implement the same contract on `et_plate_reader/scanner_<id>`:
///
/// * Dart → native: `start`, `pause`, `setTorch {on}` → bool,
///   `captureFrame` → `{path, width, height}`
/// * native → Dart: `onReady`, `onFrame {lines: [{text, confidence, left,
///   top, right, bottom}]}`, `onError {message}`
///
/// Frames never cross the channel — only recognised lines in normalized,
/// upright image coordinates.
class ChannelPlateRecognitionService extends PlateRecognitionService {
  /// Creates the service. [logger] defaults to a silent logger.
  ChannelPlateRecognitionService({Logger? logger})
      : _logger = logger ?? Logger(level: Level.off);

  /// View type registered by both native plugins.
  static const viewType = 'et_plate_reader/scanner';

  final Logger _logger;
  final _frames = StreamController<OcrFrame>.broadcast();
  final _errors = StreamController<String>.broadcast();
  MethodChannel? _channel;
  int? _viewId;
  Completer<void>? _ready;
  bool _nativeReady = false;
  bool _running = false;
  bool _disposed = false;

  @override
  Stream<OcrFrame> get frameStream => _frames.stream;

  @override
  Stream<String> get platformErrorStream => _errors.stream;

  @override
  Future<void> initialize() async {}

  /// Called by the preview once the platform view exists.
  void attach(int viewId) {
    if (_disposed) return;
    _viewId = viewId;
    final channel = MethodChannel('${viewType}_$viewId');
    channel.setMethodCallHandler(_onNativeCall);
    _channel = channel;
    _logger.d('Attached scanner view $viewId');
  }

  /// Called by the preview when its platform view goes away.
  void detach(int? viewId) {
    if (viewId == null || viewId != _viewId) return;
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _viewId = null;
    _nativeReady = false;
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'onReady':
        _nativeReady = true;
        final pending = _ready;
        if (pending != null && !pending.isCompleted) pending.complete();
        _ready = null;
        // Re-apply a start issued before the camera was bound.
        if (_running) await _invoke('start');
      case 'onFrame':
        if (!_running) return null;
        final args = call.arguments;
        if (args is Map<Object?, Object?>) {
          _frames.add(OcrFrame.fromMap(args));
        }
      case 'onError':
        final args = call.arguments;
        final message = args is Map<Object?, Object?>
            ? args['message'] as String? ?? 'Camera error'
            : 'Camera error';
        _logger.w('Native error: $message');
        _errors.add(message);
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    final channel = _channel;
    if (channel == null) return null;
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      _errors.add(e.message ?? e.code);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> ensureReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed) throw StateError('ChannelPlateRecognitionService disposed');
    if (_nativeReady) return;
    _ready ??= Completer<void>();
    await _ready!.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException('Timed out waiting for camera view', timeout);
      },
    );
  }

  @override
  Future<void> start() async {
    _running = true;
    if (_nativeReady) await _invoke('start');
  }

  @override
  Future<void> pause() async {
    _running = false;
    await _invoke('pause');
  }

  @override
  Future<CapturedFrame> captureFrame() async {
    final channel = _channel;
    if (channel == null) {
      throw PlateReaderException(
        PlateReaderErrorCode.cameraUnavailable,
        'Camera is not ready',
      );
    }
    try {
      final result =
          await channel.invokeMapMethod<String, Object?>('captureFrame');
      return CapturedFrame.fromMap(result!);
    } on PlatformException catch (e) {
      throw PlateReaderException(
        PlateReaderErrorCode.cameraUnavailable,
        e.message ?? 'Could not capture the frame',
        cause: e,
      );
    }
  }

  @override
  Future<CapturedFrame> frameImage(int id) async {
    final channel = _channel;
    if (channel == null) return grabFrame();
    try {
      final result = await channel
          .invokeMapMethod<String, Object?>('frameImage', {'id': id});
      return CapturedFrame.fromMap(result!);
    } on MissingPluginException {
      return grabFrame();
    } on PlatformException {
      // No longer kept, or not on this platform (iOS): the next frame.
      return grabFrame();
    }
  }

  @override
  Future<CapturedFrame> grabFrame() async {
    final channel = _channel;
    if (channel == null) return captureFrame();
    try {
      final result =
          await channel.invokeMapMethod<String, Object?>('grabFrame');
      return CapturedFrame.fromMap(result!);
    } on MissingPluginException {
      return captureFrame();
    } on PlatformException catch (e) {
      // iOS has no grabFrame yet: a regular still.
      if (e.code == 'notImplemented') return captureFrame();
      throw PlateReaderException(
        PlateReaderErrorCode.cameraUnavailable,
        e.message ?? 'Could not grab the frame',
        cause: e,
      );
    }
  }

  @override
  Future<AreaOcr> recognizeArea(
    String path,
    NormalizedRect area, {
    bool sectionPasses = true,
  }) =>
      PlateReader.recognizeArea(path, area, sectionPasses: sectionPasses);

  @override
  Future<List<List<String?>>> readCrops(
    String path,
    List<CropSpec> crops, {
    double size = 160,
  }) async {
    Map<String, double> rect(NormalizedRect c) => {
          'left': c.left,
          'top': c.top,
          'right': c.right,
          'bottom': c.bottom,
        };
    try {
      final result = await PlateReader.availabilityChannel
          .invokeListMethod<Object?>('readCrops', {
        'path': path,
        'size': size,
        'crops': [
          for (final c in crops)
            {
              'group': [for (final a in c.areas) rect(a)],
              'repeat': c.repeat,
            },
        ],
      });
      return [
        for (final r in result ?? const [])
          [for (final t in (r as List<Object?>)) t as String?],
      ];
    } on PlatformException catch (e) {
      throw PlateReaderException(
        PlateReaderErrorCode.channelError,
        e.message ?? 'Crops could not be read',
        cause: e,
      );
    }
  }

  @override
  Future<bool> setTorch(bool on) async {
    return await _invoke<bool>('setTorch', {'on': on}) ?? false;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _running = false;
    detach(_viewId);
    await _frames.close();
    await _errors.close();
  }

  @override
  Future<bool> isSupported() => PlateReader.isSupported();
}
