// Replays the live frames of logged sessions through the patrol tracker.
//
// dart run tool/patrol_replay.dart <et_plate_logs dir>
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/patrol/patrol_tracker.dart';

void main(List<String> args) {
  final files = Directory(args[0])
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  NormalizedRect r(Map m) => NormalizedRect((m['left'] as num).toDouble(),
      (m['top'] as num).toDouble(), (m['right'] as num).toDouble(),
      (m['bottom'] as num).toDouble());
  var sessions = 0, withVehicle = 0, multi = 0, labelled = 0, right = 0;
  for (final f in files) {
    final log = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final events = (log['events'] as List).cast<Map<String, dynamic>>();
    final frames = events.where((e) => e['event'] == 'detect').toList();
    if (frames.length < 3) continue;
    final done = events.where((e) => e['event'] == 'done').lastOrNull;
    final t0 = DateTime(2026);
    final tracker = PatrolTracker();
    for (final e in frames) {
      final lines = [
        for (final l in (e['lines'] as List).cast<Map<String, dynamic>>())
          OcrLine(
              text: l['text'] as String,
              box: r(l['box'] as Map),
              confidence: (l['confidence'] as num?)?.toDouble()),
      ];
      tracker.update(lines, t0.add(Duration(milliseconds: e['t_ms'] as int)));
    }
    final vs = [...tracker.vehicles, ...tracker.finishAll()];
    sessions++;
    if (vs.isNotEmpty) withVehicle++;
    if (vs.length > 1) multi++;
    final record = done?['record'] as String?;
    if (record != null) {
      labelled++;
      final serial = record.split('-').last;
      if (vs.any((v) => v.serial == serial)) right++;
    }
    final id = (log['session'] as String);
    stdout.writeln('${id.substring(id.length - 5)} frames=${frames.length} '
        'done=${done?['record'] ?? '-'}  ->  ${vs.join(', ')}');
  }
  stdout.writeln('sessions $sessions, with a vehicle $withVehicle, '
      'more than one $multi; confirmed plates $labelled, number found $right');
}
