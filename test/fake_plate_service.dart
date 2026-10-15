import 'dart:async';

import 'package:et_plate_reader/et_plate_reader.dart';

/// In-memory [PlateRecognitionService] for controller / widget tests.
class FakePlateService extends PlateRecognitionService {
  final _frames = StreamController<OcrFrame>.broadcast();
  final _errors = StreamController<String>.broadcast();

  bool supported = true;
  bool running = false;
  bool torch = false;
  int startCalls = 0;
  int pauseCalls = 0;
  bool disposed = false;

  void emitLines(List<String> texts, {double confidence = 0.95}) {
    final lines = <OcrLine>[];
    for (var i = 0; i < texts.length; i++) {
      final top = 0.4 + i * 0.1;
      lines.add(
        OcrLine(
          text: texts[i],
          box: NormalizedRect(0.2, top, 0.8, top + 0.08),
          confidence: confidence,
        ),
      );
    }
    _frames.add(OcrFrame(lines: lines, timestamp: DateTime(2026)));
  }

  void emitFrame(List<OcrLine> lines) =>
      _frames.add(OcrFrame(lines: lines, timestamp: DateTime(2026)));

  void emitError(String message) => _errors.add(message);

  @override
  Stream<OcrFrame> get frameStream => _frames.stream;

  @override
  Stream<String> get platformErrorStream => _errors.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> ensureReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {}

  @override
  Future<void> start() async {
    running = true;
    startCalls++;
  }

  @override
  Future<void> pause() async {
    running = false;
    pauseCalls++;
  }

  @override
  Future<bool> setTorch(bool on) async => torch = on;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _frames.close();
    await _errors.close();
  }

  @override
  Future<bool> isSupported() async => supported;
}
