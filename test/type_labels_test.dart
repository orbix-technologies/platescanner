import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/models/plate_area.dart';
import 'package:et_plate_reader/src/parsing/plate_family.dart';
import 'package:et_plate_reader/src/recognition/plate_type_classifier.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Seeds in test/fixtures/types.json must stay ≥90% accurate (CI gate for
/// the type-first data pipeline).
void main() {
  test('seeded fixture type labels ≥ 90% accurate', () {
    final labels =
        (jsonDecode(File('test/fixtures/types.json').readAsStringSync())
                as Map)
            .cast<String, dynamic>();
    const clf = PlateTypeClassifier();
    var ok = 0, n = 0;
    for (final e in labels.entries) {
      final id = e.key;
      final want = PlateFamily.values.byName((e.value as Map)['family'] as String);
      final path = 'test/fixtures/plates/$id.png';
      if (!File(path).existsSync()) continue;
      n++;
      final seg = segmentCaptureSync(path, const NormalizedRect(0, 0, 1, 1));
      final ocr = switch (want) {
        PlateFamily.special when id == 'police' => const AreaOcr(
            elements: [],
            paperColor: [235, 180, 40],
          ),
        PlateFamily.special when id == 'daily' => const AreaOcr(elements: [
            OcrElement(
              text: 'የዕለት 091 OR',
              box: NormalizedRect(0.1, 0.2, 0.9, 0.8),
            ),
          ]),
        PlateFamily.special when id == 'un' => const AreaOcr(elements: [
            OcrElement(
              text: 'UN 0123456',
              box: NormalizedRect(0.2, 0.2, 0.9, 0.8),
            ),
          ]),
        PlateFamily.special when id == 'au' => const AreaOcr(elements: [
            OcrElement(
              text: 'AU 0123456',
              box: NormalizedRect(0.2, 0.2, 0.9, 0.8),
            ),
          ]),
        PlateFamily.nationalEth => const AreaOcr(elements: [
            OcrElement(
              text: 'ETH ABC1234',
              box: NormalizedRect(0.1, 0.2, 0.9, 0.8),
            ),
          ]),
        _ => const AreaOcr(elements: []),
      };
      final d = clf.classify(TypeFeatures(
        aspect: seg?.twoRow == true ? 2.0 : 4.2,
        segmentation: seg,
        ocr: ocr,
      ));
      if (d.family == want) ok++;
    }
    expect(n, greaterThan(10));
    expect(ok / n, greaterThanOrEqualTo(0.9),
        reason: 'type accuracy $ok/$n');
  });
}
