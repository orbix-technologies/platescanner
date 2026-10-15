import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_replay.dart';

/// Replays session logs pulled from a device through the arranger.
///
/// `LOGS_DIR=/path/to/et_plate_logs flutter test test/replay_logs_test.dart`
void main() {
  final dir = Platform.environment['LOGS_DIR'];
  test('replay', () {
    for (final f in Directory(dir!).listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path))) {
      if (!f.path.endsWith('.json')) continue;
      final ocr = areaOcrFromSession(f);
      if (ocr == null) continue;
      final r = const PlateArranger().arrange(ocr);
      // ignore: avoid_print
      print('${f.uri.pathSegments.last}  ${ocr.text}  ->  '
          '${r.arrangement.layoutText}  ignored=${r.arrangement.ignored}');
    }
  }, skip: dir == null ? 'set LOGS_DIR' : false);
}
