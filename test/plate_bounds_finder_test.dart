import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/plate_bounds_finder.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

  test('real plates have their top and bottom edges; screen text never does',
      () {
    for (final c in manifest.where((c) => c['expected'] != null)) {
      final b = findCaptureBoundsSync(
          'test/fixtures/stills/${c['id']}.jpg', rect(c['seed'] as List));
      expect(b?.isPlate, isTrue, reason: '${c['id']}');
    }
    // A page of text, dark on light (a document, a light-theme screen).
    final page = img.Image(width: 886, height: 1920);
    img.fill(page, color: img.ColorRgb8(250, 250, 250));
    for (var y = 100, i = 0; y < 1800; y += 60, i++) {
      img.drawString(page, i.isEven ? '34585 device' : '95024 verbose',
          font: img.arial48, x: 40, y: y, color: img.ColorRgb8(20, 20, 20));
    }
    final path = '${Directory.systemTemp.createTempSync().path}/page.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(page));
    for (var y = 100; y < 1800; y += 120) {
      // Seed around "34585" on that line, as patrol searches.
      final h = 48 / 1920, top = y / 1920;
      final seed = NormalizedRect((40 - 1.6 * 48) / 886, top - 0.5 * h,
          (40 + 130 + 0.9 * 48) / 886, top + 1.5 * h);
      expect(findCaptureBoundsSync(path, seed)?.isPlate ?? false, isFalse,
          reason: 'line at $y');
    }
  });
}
