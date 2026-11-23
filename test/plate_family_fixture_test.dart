import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/models/plate_area.dart';
import 'package:et_plate_reader/src/parsing/plate_family.dart';
import 'package:et_plate_reader/src/recognition/plate_type_classifier.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Expected family from geometry alone (OCR text empty except where noted).
final cases = <String, PlateFamily>{
  'real_c06703': PlateFamily.classicSingle,
  'af': PlateFamily.classicSingle,
  'two_row_04765': PlateFamily.classicTwoRow,
  'two_row_a45699': PlateFamily.classicTwoRow,
  'police': PlateFamily.special,
  'cd': PlateFamily.special,
  'un': PlateFamily.special,
};

void main() {
  const clf = PlateTypeClassifier();

  for (final e in cases.entries) {
    test('${e.key} → ${e.value.name}', () {
      final path = 'test/fixtures/plates/${e.key}.png';
      expect(File(path).existsSync(), isTrue);
      final seg = segmentCaptureSync(path, const NormalizedRect(0, 0, 1, 1));
      final d = clf.classify(TypeFeatures(
        aspect: 1.0 / 1.0 * (seg?.twoRow == true ? 2.0 : 4.2),
        segmentation: seg,
        ocr: e.key == 'un'
            ? const AreaOcr(elements: [
                OcrElement(
                  text: 'UN',
                  box: NormalizedRect(0.8, 0.2, 0.95, 0.8),
                ),
              ])
            : e.key == 'police'
                ? const AreaOcr(
                    elements: [],
                    paperColor: [235, 180, 40],
                  )
                : const AreaOcr(elements: []),
      ));
      expect(d.family, e.value, reason: d.reasons.join(', '));
    });
  }

  test('national_new → nationalEth when OCR has AAA####', () {
    final path = 'test/fixtures/plates/national_new.png';
    if (!File(path).existsSync()) return;
    final seg = segmentCaptureSync(path, const NormalizedRect(0, 0, 1, 1));
    final d = clf.classify(TypeFeatures(
      aspect: 4.0,
      segmentation: seg,
      ocr: const AreaOcr(elements: [
        OcrElement(
          text: 'ETH ABC1234',
          box: NormalizedRect(0.1, 0.2, 0.9, 0.8),
        ),
      ]),
    ));
    expect(d.family, PlateFamily.nationalEth);
  });
}
