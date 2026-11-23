import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/models/plate_record.dart';
import 'package:et_plate_reader/src/recognition/typed_plate_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

PlateCandidate cand({
  String? code = '2',
  String? region = 'AA',
  String? serial = 'C06703',
  double confidence = 0.9,
  List<PlateIssue> issues = const [],
}) =>
    PlateCandidate(
      code: code,
      regionCode: region,
      serial: serial,
      layout: PlateLayout.singleRow,
      rawText: '$code-$region-$serial',
      confidence: confidence,
      issues: issues,
    );

void main() {
  group('TypedPlateReader.shouldEarlyExit', () {
    test('accepts strong OCR with no glyph', () {
      expect(
        TypedPlateReader.shouldEarlyExit(ocr: cand()),
        isTrue,
      );
    });

    test('accepts when glyph key matches', () {
      expect(
        TypedPlateReader.shouldEarlyExit(
          ocr: cand(),
          glyph: cand(confidence: 0.7),
        ),
        isTrue,
      );
    });

    test('rejects when glyph key disagrees', () {
      expect(
        TypedPlateReader.shouldEarlyExit(
          ocr: cand(),
          glyph: cand(serial: 'B05475'),
        ),
        isFalse,
      );
    });

    test('rejects low confidence', () {
      expect(
        TypedPlateReader.shouldEarlyExit(ocr: cand(confidence: 0.84)),
        isFalse,
      );
    });

    test('rejects empty serial', () {
      expect(
        TypedPlateReader.shouldEarlyExit(ocr: cand(serial: '')),
        isFalse,
      );
      expect(
        TypedPlateReader.shouldEarlyExit(ocr: cand(serial: null)),
        isFalse,
      );
    });

    test('allows missingCode alone', () {
      expect(
        TypedPlateReader.shouldEarlyExit(
          ocr: cand(issues: const [PlateIssue.missingCode]),
        ),
        isTrue,
      );
    });

    test('rejects missingRegion or missingSerial', () {
      expect(
        TypedPlateReader.shouldEarlyExit(
          ocr: cand(issues: const [PlateIssue.missingRegion]),
        ),
        isFalse,
      );
      expect(
        TypedPlateReader.shouldEarlyExit(
          ocr: cand(issues: const [PlateIssue.missingSerial]),
        ),
        isFalse,
      );
    });
  });

  group('PreparedStill', () {
    test('loadSync reuses bytes for segment and gray', () {
      const path = 'test/fixtures/plates/real_c06703.png';
      expect(File(path).existsSync(), isTrue);
      final still = PreparedStill.loadSync(path);
      expect(still, isNotNull);
      expect(still!.bytes, isNotEmpty);

      const area = NormalizedRect(0, 0, 1, 1);
      final a = segmentCaptureSync(path, area, still: still);
      final b = segmentCaptureSync(path, area, still: still);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.found, isTrue);
      expect(b!.found, isTrue);
      expect(a.numberChars.length, b.numberChars.length);

      final gray = plateGraySync(path, area, still: still);
      expect(gray, isNotNull);
      expect(gray!.width, greaterThan(0));
    });
  });
}
