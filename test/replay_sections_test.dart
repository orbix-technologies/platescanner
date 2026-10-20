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
    final files = Directory(dir!)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
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
      final crops = [
        ...reader.cropsFor(seg, area),
        ...reader.cropsFor(seg, area, digits: true)
      ];
      final reads = [
        for (final c in crops)
          logged['${c.role}${c.index}'] ?? const <String?>[null, null, null]
      ];
      // The logged whole-area pass: colours and circle hint.
      final o = events.where((e) => e['event'] == 'areaOcr').lastOrNull;
      List<int>? rgb(Object? v) =>
          (v as List?)?.whereType<num>().map((x) => x.toInt()).toList();
      NormalizedRect box(Object? m) {
        final b = (m as Map).cast<String, num>();
        return NormalizedRect(b['left']!.toDouble(), b['top']!.toDouble(),
            b['right']!.toDouble(), b['bottom']!.toDouble());
      }

      final ocr = AreaOcr(
        elements: [
          for (final e in (o?['elements'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
            OcrElement(text: e['text'] as String, box: box(e['box'])),
        ],
        codeHint: o?['codeHint'] as String?,
        codeVotes: (o?['codeVotes'] as num?)?.toInt(),
        inkColor: rgb(o?['inkColor']),
        paperColor: rgb(o?['paperColor']),
      );
      final r = reader.read(seg, crops, reads, ocr);
      final id = log['session'] as String;
      // ignore: avoid_print
      print('${id.substring(id.length - 5)}  ${r.arrangement.layoutText}'
          '  ${r.arrangement.code.note ?? ''}');
    }
  }, skip: dir == null ? 'set LOGS_DIR' : false);
}
