import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replays logged sessions (photo + recorded crop reads) through the
/// current segmenter and section reader.
///
/// `LOGS_DIR=/path/to/et_plate_logs flutter test test/replay_sections_test.dart`
void main() {
  final dir = Platform.environment['LOGS_DIR'];
  test('replay sections', () async {
    const reader = PlateSectionReader();
    final files = Directory(dir!).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final log = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final events = (log['events'] as List).cast<Map<String, dynamic>>();
      final cropsEv = events.where((e) => e['event'] == 'crops').lastOrNull;
      final ca = events.where((e) => e['event'] == 'confirmArea').lastOrNull;
      if (cropsEv == null || ca == null) continue;
      final a = (ca['area'] as Map).cast<String, num>();
      final area = NormalizedRect(a['left']!.toDouble(), a['top']!.toDouble(),
          a['right']!.toDouble(), a['bottom']!.toDouble());
      final seg = segmentCaptureSync(f.path.replaceAll('.json', '.jpg'), area);
      if (seg == null || !seg.found) continue;
      final logged = <String, List<String?>>{
        for (final c in (cropsEv['crops'] as List).cast<Map<String, dynamic>>())
          '${c['role']}${c['index']}': (c['reads'] as List).cast<String?>(),
      };
      final crops = [...reader.cropsFor(seg, area), ...reader.cropsFor(seg, area, digits: true)];
      final reads = [for (final c in crops) logged['${c.role}${c.index}'] ?? const <String?>[null, null, null]];
      final r = reader.read(seg, crops, reads, const AreaOcr(elements: []));
      final id = log['session'] as String;
      // ignore: avoid_print
      print('${id.substring(id.length - 5)}  ${r.arrangement.layoutText}');
    }
  }, skip: dir == null ? 'set LOGS_DIR' : false);
}
