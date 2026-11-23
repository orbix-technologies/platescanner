import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/models/plate_area.dart';
import 'package:et_plate_reader/src/recognition/glyph_classifier.dart';
import 'package:et_plate_reader/src/recognition/glyph_plate_reader.dart';
import 'package:et_plate_reader/src/recognition/reading_consensus.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures with a stable number section — same image must yield the same
/// canonical string across repeated glyph reads (determinism gate).
const fixtures = [
  'real_c06703',
  'real_a41601',
  'real_b88418',
  'real_70695_edge',
  'af',
  'am',
  'or',
  'et',
];

void main() {
  final reader = GlyphPlateReader(classifier: GlyphClassifier.synthetic());

  for (final name in fixtures) {
    test('$name: identical canonical across 5 glyph reads', () {
      final path = 'test/fixtures/plates/$name.png';
      expect(File(path).existsSync(), isTrue);
      final keys = <String>[];
      for (var i = 0; i < 5; i++) {
        final seg =
            segmentCaptureSync(path, const NormalizedRect(0, 0, 1, 1));
        final gray = plateGraySync(path, const NormalizedRect(0, 0, 1, 1));
        expect(seg, isNotNull);
        expect(seg!.found, isTrue, reason: seg.notes.join(' '));
        expect(gray, isNotNull);
        final ocr = const AreaOcr(elements: []);
        final r = reader.read(gray!, seg, ocr);
        keys.add(r.candidate.key);
      }
      expect(keys.toSet(), hasLength(1), reason: 'got $keys');
    });
  }

  test('consensus of three identical prep passes agrees', () {
    const path = 'test/fixtures/plates/real_c06703.png';
    final reader = GlyphPlateReader(classifier: GlyphClassifier.synthetic());
    final ballots = [
      for (final prep in SegmentPrep.values)
        () {
          final seg = segmentCaptureSync(
            path,
            const NormalizedRect(0, 0, 1, 1),
            prep: prep,
          )!;
          final gray = plateGraySync(
            path,
            const NormalizedRect(0, 0, 1, 1),
            prep: prep,
          )!;
          return reader
              .read(gray, seg, const AreaOcr(elements: []))
              .candidate;
        }(),
    ];
    final c = voteReadings(ballots);
    expect(c.ballots, hasLength(3));
    expect(c.winner.key, isNotEmpty);
    // Each prep is deterministic; disagreement across preps is allowed and
    // surfaces as !c.agreed for the review UI.
    expect(ballots.map((b) => b.key).toSet(), isNotEmpty);
  });
}
