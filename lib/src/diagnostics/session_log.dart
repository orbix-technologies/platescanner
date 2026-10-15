import 'dart:convert';
import 'dart:io';

import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';

/// Records one scan session to a JSON file for later diagnosis.
///
/// Written next to the captured stills, in `et_plate_logs/` inside the app's
/// cache directory:
///
/// * `session_<start>.json` — every event, with raw OCR (text, confidence,
///   boxes per character), what the native code / region passes tried and
///   read, the sections, the reading, edits and how the session ended;
/// * `session_<start>.jpg` — the captured frame the reading was made from.
///
/// Pull from an Android debug build with:
/// `adb exec-out run-as <app id> tar c cache/et_plate_logs | tar x`
class SessionLog {
  /// Starts a log for a session beginning now.
  SessionLog() : _start = DateTime.now();

  final DateTime _start;
  final List<Map<String, Object?>> _events = [];
  String? _framePath;
  int _detectionsLogged = 0;

  /// Detection events kept per session (frames arrive ~10–20 per second).
  static const _maxDetections = 40;

  String get _id => '${_start.millisecondsSinceEpoch}';

  /// Adds an event.
  void event(String name, [Map<String, Object?> data = const {}]) {
    _events.add({
      't_ms': DateTime.now().difference(_start).inMilliseconds,
      'event': name,
      ...data,
    });
  }

  /// Adds a live detection event (capped per session).
  void detection(List<OcrLine> lines, NormalizedRect? area) {
    if (_detectionsLogged >= _maxDetections) return;
    _detectionsLogged++;
    event('detect', {
      'lines': [for (final l in lines) _line(l)],
      'area': rect(area),
    });
  }

  /// Remembers the captured frame to copy beside the log.
  void frame(CapturedFrame frame) => _framePath = frame.path;

  /// Writes the log (and the frame) now. Safe to call repeatedly: the same
  /// files are overwritten as the session goes on. Never throws.
  Future<void> save() async {
    final framePath = _framePath;
    if (framePath == null) return; // nowhere to write before a capture
    try {
      final dir = Directory('${File(framePath).parent.path}/et_plate_logs');
      await dir.create(recursive: true);
      final image = File('${dir.path}/session_$_id.jpg');
      if (!await image.exists()) await File(framePath).copy(image.path);
      final json = const JsonEncoder.withIndent('  ').convert({
        'session': _id,
        'started': _start.toIso8601String(),
        'platform': Platform.operatingSystem,
        'frame': image.path,
        'events': _events,
      });
      await File('${dir.path}/session_$_id.json').writeAsString(json);
    } catch (_) {
      // Diagnostics must never break scanning.
    }
  }

  /// JSON for a box.
  static Map<String, double>? rect(NormalizedRect? r) => r == null
      ? null
      : {
          'left': _r(r.left),
          'top': _r(r.top),
          'right': _r(r.right),
          'bottom': _r(r.bottom),
        };

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;

  static Map<String, Object?> _line(OcrLine l) => {
        'text': l.text,
        'confidence': l.confidence,
        'box': rect(l.box),
      };

  /// JSON for the raw OCR of a confirmed area.
  static Map<String, Object?> areaOcr(AreaOcr ocr) => {
        'elements': [
          for (final e in ocr.elements)
            {
              'text': e.text,
              'confidence': e.confidence,
              'box': rect(e.box),
              'symbols': [
                for (final s in e.symbols) {'text': s.text, 'box': rect(s.box)},
              ],
            },
        ],
        'codeHint': ocr.codeHint,
        'regionColumns': [
          for (final c in ocr.regionColumns)
            {
              'letters': c.letters,
              'source': c.source,
              'box': rect(c.box),
            },
        ],
        'nativePasses': ocr.debug,
      };

  /// JSON for the four sections.
  static Map<String, Object?> arrangement(PlateArrangement a) => {
        'layout': a.layoutText,
        'sections': [
          for (final s in a.sections)
            {
              'kind': s.kind.name,
              'value': s.value,
              'detected': s.detected,
              'box': rect(s.box),
              'chars': [
                for (final c in s.chars) {'text': c.text, 'box': rect(c.box)},
              ],
            },
        ],
        'ignored': [
          for (final c in a.ignored) {'text': c.text, 'box': rect(c.box)},
        ],
      };

  /// JSON for a reading.
  static Map<String, Object?> candidate(PlateCandidate c) => {
        'code': c.code,
        'region': c.regionCode,
        'serial': c.serial,
        'confidence': c.confidence,
        'issues': [for (final i in c.issues) i.name],
      };
}
