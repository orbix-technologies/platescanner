// Reads labelled street photos on the phone with the real pipeline
// (segmentation, ML Kit, section reader) exactly as the controller does
// after the area is confirmed, and scores code / region / number.
//
// Put session_<id>.json + .jpg and a labels.json ({"<id>": "3-AA-A20650"})
// in the app's cache/eval/, e.g.:
//   adb push <dir> /data/local/tmp/et_eval
//   adb shell run-as <app id> cp -r /data/local/tmp/et_eval cache/eval
// then:
//   cd example && flutter drive --keep-app-running \
//       --driver=test_driver/integration_test.dart \
//       --target=integration_test/real_plates_test.dart
// Prints one line per photo and the totals; fails only if nothing ran.
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/recognition/channel_plate_recognition_service.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Directory get _evalDir {
  final temp = Directory.systemTemp.path;
  final cache = temp.endsWith('/code_cache')
      ? '${temp.substring(0, temp.length - 'code_cache'.length)}cache'
      : temp;
  return Directory('$cache/eval');
}

NormalizedRect? _rect(Object? m) {
  if (m == null) return null;
  final a = (m as Map).cast<String, num>();
  return NormalizedRect(a['left']!.toDouble(), a['top']!.toDouble(),
      a['right']!.toDouble(), a['bottom']!.toDouble());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('labelled street photos', (tester) async {
    final dir = _evalDir;
    final labels = (jsonDecode(File('${dir.path}/labels.json')
            .readAsStringSync()) as Map<String, dynamic>)
        .cast<String, String>();
    final service = ChannelPlateRecognitionService();
    const reader = PlateSectionReader();
    const arranger = PlateArranger();
    final ok = {'code': 0, 'region': 0, 'number': 0, 'all': 0};
    var n = 0;

    for (final MapEntry(key: id, value: label) in labels.entries) {
      final log = jsonDecode(
              File('${dir.path}/session_$id.json').readAsStringSync())
          as Map<String, dynamic>;
      final events = (log['events'] as List).cast<Map<String, dynamic>>();
      final area = _rect(events
          .lastWhere((e) => e['event'] == 'confirmArea' ||
              e['event'] == 'capture')
          .let((e) => e['area'] ?? e['detected']));
      if (area == null) continue;
      final photo = '${dir.path}/session_$id.jpg';

      final seg = await segmentCapture(photo, area);
      final segmented = seg != null && seg.found;
      final ocr = await service.recognizeArea(photo, area,
          sectionPasses: !segmented);
      ({PlateArrangement arrangement, PlateCandidate candidate}) result;
      var crops = <SectionCrop>[];
      var reads = <List<String?>>[];
      if (segmented) {
        crops = reader.cropsFor(seg, area);
        reads =
            await service.readCrops(photo, [for (final c in crops) c.spec]);
        result = reader.read(seg, crops, reads, ocr);
        if (result.arrangement.number.value.isEmpty) {
          final digits = reader.cropsFor(seg, area, digits: true);
          final more =
              await service.readCrops(photo, [for (final c in digits) c.spec]);
          crops = [...crops, ...digits];
          reads = [...reads, ...more];
          result = reader.read(seg, crops, reads, ocr);
        }
      } else {
        result = arranger.arrange(ocr);
      }

      final c = result.candidate;
      final [code, region, serial] = label.split('-');
      final hits = {
        'code': c.code == code,
        'region': c.regionCode == region,
        'number': c.serial == serial,
      };
      hits['all'] = hits.values.every((h) => h);
      n++;
      for (final k in hits.keys) {
        if (hits[k]!) ok[k] = ok[k]! + 1;
      }
      final miss = [
        for (final k in ['code', 'region', 'number'])
          if (!hits[k]!) k
      ];
      // ignore: avoid_print
      print('EVAL $id  want $label  got ${c.code}-${c.regionCode}-'
          '${c.serial}  ${result.arrangement.layoutText}'
          '${segmented ? '' : '  [not segmented]'}'
          '${miss.isEmpty ? '  OK' : '  MISS ${miss.join(',')}'}');
      if (miss.contains('region') || miss.contains('code')) {
        // ignore: avoid_print
        print('EVAL   stacks geez ${seg?.geezStack.length} latin '
            '${seg?.latinStack.length} twoRow ${seg?.twoRow} code '
            '${seg?.code != null}  reads ${[
          for (var k = 0; k < crops.length; k++)
            if (crops[k].role.startsWith('latin') ||
                crops[k].role.startsWith('code'))
              '${crops[k].role}${crops[k].index}=${reads[k].map((r) => r?.replaceAll('\n', '/'))}'
        ].join(' ')}');
      }
    }
    // ignore: avoid_print
    print('EVAL TOTAL $n photos: '
        '${ok.entries.map((e) => '${e.key} ${e.value}/$n').join('  ')}');
    expect(n, greaterThan(0));
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
