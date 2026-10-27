// Replays a logged patrol (patrol_<time>.json) through the current tracker.
//
// dart run tool/patrol_log_replay.dart <patrol_....json>
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/patrol/patrol_tracker.dart';

void main(List<String> args) {
  final log = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  NormalizedRect r(Map m) => NormalizedRect((m['left'] as num).toDouble(),
      (m['top'] as num).toDouble(), (m['right'] as num).toDouble(),
      (m['bottom'] as num).toDouble());
  final t0 = DateTime.parse(log['started'] as String);
  final tracker = PatrolTracker();
  for (final f in (log['frames'] as List).cast<Map>()) {
    tracker.update([
      for (final l in (f['lines'] as List).cast<Map>())
        OcrLine(text: l['text'] as String, box: r(l['box'] as Map)),
    ], t0.add(Duration(milliseconds: f['t_ms'] as int)));
  }
  tracker.finishAll();
  final vs = tracker.vehicles;
  stdout.writeln('${vs.length} vehicles, '
      '${vs.where((v) => v.needsCheck).length} to check');
  for (final v in vs) {
    stdout.writeln('  $v${v.embassy == null ? '' : ' embassy ${v.embassy}'}');
  }
}
