import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/plate_bounds_finder.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real stills (cropped around the search window) with the logged proposed
/// area as seed and the plate area checked by eye.
void main() {
  final manifest =
      (jsonDecode(File('test/fixtures/stills/stills.json').readAsStringSync())
              as List)
          .cast<Map<String, dynamic>>();

  NormalizedRect rect(List<dynamic> v) => NormalizedRect(
      (v[0] as num).toDouble(),
      (v[1] as num).toDouble(),
      (v[2] as num).toDouble(),
      (v[3] as num).toDouble());

  double iou(NormalizedRect a, NormalizedRect b) {
    final w = (a.right < b.right ? a.right : b.right) -
        (a.left > b.left ? a.left : b.left);
    final h = (a.bottom < b.bottom ? a.bottom : b.bottom) -
        (a.top > b.top ? a.top : b.top);
    if (w <= 0 || h <= 0) return 0;
    final i = w * h;
    return i / (a.width * a.height + b.width * b.height - i);
  }

  for (final c in manifest) {
    test('${c['id']}: ${c['note']}', () {
      final found = snapCaptureAreaSync(
          'test/fixtures/stills/${c['id']}.jpg', rect(c['seed'] as List));
      final expected = c['expected'] as List?;
      if (expected == null) {
        expect(found, isNull);
        return;
      }
      expect(found, isNotNull);
      final e = rect(expected);
      expect(iou(found!, e), greaterThan(0.85),
          reason: 'found $found, expected $e');
      // Snapping fixes the seed: never worse than what was proposed.
      expect(iou(found, e), greaterThanOrEqualTo(iou(rect(c['seed']), e)));
    });
  }

  test('blank image: no plate', () {
    final blank =
        GrayImage(400, 300, Uint8List(400 * 300)..fillRange(0, 400 * 300, 200));
    expect(
      const PlateBoundsFinder()
          .find(blank, const NormalizedRect(0.2, 0.4, 0.8, 0.6)),
      isNull,
    );
  });
}
