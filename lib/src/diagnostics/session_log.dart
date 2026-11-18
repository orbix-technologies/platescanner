import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/plate_section_reader.dart';
import '../segmentation/plate_segmenter.dart';

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
/// Every attempt is logged, including ones that never captured a still
/// (cancelled, closed with back, or the app killed): those have a JSON file
/// with no `.jpg` and `frame: null`. The file is saved at the start and
/// every few detections, so its last event shows how far the scan got.
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

  /// Detection events between saves while no still was captured yet.
  static const _saveEvery = 5;

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
  ///
  /// Saves every [_saveEvery] logged detections, so a session that never
  /// reaches a capture is still on disk.
  void detection(
    List<OcrLine> lines,
    NormalizedRect? area, {
    List<DetectedPlate> plates = const [],
  }) {
    if (_detectionsLogged >= _maxDetections) return;
    _detectionsLogged++;
    if (_detectionsLogged % _saveEvery == 0) unawaited(save());
    event('detect', {
      'lines': [for (final l in lines) _line(l)],
      'area': rect(area),
      if (plates.isNotEmpty)
        'plates': [
          for (final p in plates) {...?rect(p.box), 'score': p.score},
        ],
    });
  }

  /// Remembers the captured frame to copy beside the log.
  void frame(CapturedFrame frame) => _framePath = frame.path;

  /// Where logs go before any still was captured: the directory the stills
  /// are written to, so all logs land in one `et_plate_logs/`.
  @visibleForTesting
  static String? fallbackDirectory;

  /// The app's cache directory, where the native scanner writes stills.
  /// Flutter's temp directory is `code_cache/` on Android (its sibling
  /// `cache/` is `Context.cacheDir`) and `tmp/` on iOS.
  static String get _cacheDirectory {
    final temp = Directory.systemTemp.path;
    if (Platform.isAndroid && temp.endsWith('/code_cache')) {
      return '${temp.substring(0, temp.length - 'code_cache'.length)}cache';
    }
    return temp;
  }

  Future<void> _saving = Future.value();

  /// Writes the log (and the frame, once there is one) now. Safe to call
  /// repeatedly: the same files are overwritten as the session goes on, so a
  /// session that never captured, or that the app was killed in, still
  /// leaves a log. Saves run one after another. Never throws.
  Future<void> save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    final framePath = _framePath;
    try {
      final base = framePath != null
          ? File(framePath).parent.path
          : fallbackDirectory ?? _cacheDirectory;
      final dir = Directory('$base/et_plate_logs');
      await dir.create(recursive: true);
      File? image;
      if (framePath != null) {
        image = File('${dir.path}/session_$_id.jpg');
        if (!await image.exists()) await File(framePath).copy(image.path);
      }
      final json = const JsonEncoder.withIndent('  ').convert({
        'session': _id,
        'started': _start.toIso8601String(),
        'platform': Platform.operatingSystem,
        'frame': image?.path,
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
        'inkColor': ocr.inkColor,
        'paperColor': ocr.paperColor,
        'codeVotes': ocr.codeVotes,
        'nativePasses': ocr.debug,
      };

  /// JSON for an image segmentation (boxes normalized to the plate area).
  static Map<String, Object?> segmentation(PlateSegmentation s) => {
        'found': s.found,
        'number': rect(s.number),
        'numberChars': [for (final r in s.numberChars) rect(r)],
        'code': rect(s.code),
        'codeInner': rect(s.codeInner),
        'geezStack': [for (final r in s.geezStack) rect(r)],
        'latinStack': [for (final r in s.latinStack) rect(r)],
        'leftDigits': [for (final r in s.leftDigits) rect(r)],
        'leftWord': [for (final r in s.leftWord) rect(r)],
        'latinSideBySide': s.latinSideBySide,
        'twoRow': s.twoRow,
        'columns': [
          for (final c in s.columns)
            '${c.kind.name}${c.strictStack ? '*' : ''} ${c.box.left},${c.box.top} '
                '${c.box.width}x${c.box.height} (${c.blobs.length})',
        ],
        'notes': s.notes,
      };

  /// JSON for the section crops and what each read gave.
  static List<Map<String, Object?>> crops(
    List<SectionCrop> crops,
    List<List<String?>> reads,
  ) =>
      [
        for (var i = 0; i < crops.length; i++)
          {
            'role': crops[i].role,
            'index': crops[i].index,
            if (crops[i].group.length > 1) 'parts': crops[i].group.length,
            if (crops[i].repeat > 1) 'repeat': crops[i].repeat,
            'box': rect(crops[i].inArea),
            'reads': i < reads.length ? reads[i] : null,
          },
      ];

  /// JSON for the four sections.
  static Map<String, Object?> arrangement(PlateArrangement a) => {
        'layout': a.layoutText,
        'sections': [
          for (final s in a.sections)
            {
              'kind': s.kind.name,
              'value': s.value,
              'note': s.note,
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
