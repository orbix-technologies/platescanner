// Turns every logged scan photo as if the plate were seen at an angle (a
// car parked at 45° as a walker passes it), then snaps and segments it, to
// compare with the straight-on photo.
//
// dart run tool/angle_sim.dart <et_plate_logs dir> <out dir>
// ANGLE=45 (degrees; both directions are tried), ONLY=<id,...>
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';

void main(List<String> args) {
  final dir = Directory(args[0]);
  final out = Directory(args[1])..createSync(recursive: true);
  final only = Platform.environment['ONLY']?.split(',');
  final angle =
      double.parse(Platform.environment['ANGLE'] ?? '45') * math.pi / 180;
  final tiles = <img.Image>[];
  final totals = <String, int>{};
  void count(String k, bool ok) {
    totals[k] = (totals[k] ?? 0) + (ok ? 1 : 0);
    totals['$k/n'] = (totals['$k/n'] ?? 0) + 1;
  }

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    if (only != null && !only.any((id) => f.path.contains(id))) continue;
    final log = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final events = ((log['events'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final cap = events.where((e) => e['event'] == 'capture').lastOrNull;
    final ca = events.where((e) => e['event'] == 'confirmArea').lastOrNull;
    final jpg = File(f.path.replaceAll('.json', '.jpg'));
    if (cap == null || ca == null || !jpg.existsSync()) continue;
    if (cap['proposed'] == null) continue;
    NormalizedRect rect(Object? m) {
      final a = (m as Map).cast<String, num>();
      return NormalizedRect(a['left']!.toDouble(), a['top']!.toDouble(),
          a['right']!.toDouble(), a['bottom']!.toDouble());
    }

    final seed = rect(cap['proposed']);
    final truth = rect(ca['area']);
    final photo = img.decodeJpg(jpg.readAsBytesSync())!;
    final id = (log['session'] as String);
    final short = id.substring(id.length - 5);

    final straight = _run(jpg.path, seed);
    if (straight.seg == null || straight.seg!.numberChars.isEmpty) continue;
    for (final sign in [1.0, -1.0]) {
      final w = _Warp(photo, truth, sign * angle);
      final path = '${out.path}/w.jpg';
      File(path).writeAsBytesSync(img.encodeJpg(w.image, quality: 92));
      final turned = _run(path, w.rect(seed));
      final t = w.rect(straight.area ?? truth);
      final a = turned.area;
      final iou = a == null ? 0.0 : _iou(a, t);
      final s0 = straight.seg!, s1 = turned.seg;
      count('snapped', turned.snapped);
      count('area ok (IoU>=0.7)', iou >= 0.7);
      // The number box (read whole) should span the same digits.
      NormalizedRect? inPhoto(NormalizedRect? area, NormalizedRect? q) =>
          area == null || q == null
              ? null
              : NormalizedRect(
                  area.left + q.left * area.width,
                  area.top + q.top * area.height,
                  area.left + q.right * area.width,
                  area.top + q.bottom * area.height);
      final n0 = inPhoto(straight.area, s0.number);
      final want = n0 == null ? null : w.rect(n0);
      final got = inPhoto(a, s1?.number);
      final pitch = want == null ? 0.0 : want.width / s0.numberChars.length;
      final numberOk = want != null &&
          got != null &&
          (got.left - want.left).abs() < 0.6 * pitch &&
          (got.right - want.right).abs() < 0.6 * pitch;
      count('number box same', numberOk);
      if (s0.code != null) count('circle kept', s1?.code != null);
      if (s0.latinStack.isNotEmpty) {
        count('latin kept', s1?.latinStack.length == s0.latinStack.length);
      }
      if (s0.geezStack.isNotEmpty) {
        count('geez kept', s1?.geezStack.length == s0.geezStack.length);
      }
      if (s0.twoRow) count('two-row kept', s1?.twoRow ?? false);
      final bad = iou < 0.7 ||
          s1 == null ||
          !numberOk ||
          (s0.code != null && s1.code == null) ||
          s1.latinStack.length != s0.latinStack.length;
      final label = '$short ${numberOk ? '' : 'NUM '} ${sign > 0 ? 'L' : 'R'} iou=${iou.toStringAsFixed(2)}'
          ' n=${s0.numberChars.length}>${s1?.numberChars.length}'
          ' c=${s0.code != null ? 1 : 0}>${s1?.code != null ? 1 : 0}'
          ' lat=${s0.latinStack.length}>${s1?.latinStack.length}'
          ' gz=${s0.geezStack.length}>${s1?.geezStack.length}'
          ' 2r=${s0.twoRow ? 1 : 0}>${(s1?.twoRow ?? false) ? 1 : 0}'
          ' ${s1?.notes.join(' ') ?? ''}';
      stdout.writeln('${bad ? 'BAD ' : 'ok  '}$label');
      if (Platform.environment['COLS'] != null && s1 != null) {
        for (final c in s1.columns) {
          stdout.writeln('    ${c.kind.name.padRight(6)} ${c.blobs.map((b) => '${b.left},${b.top} ${b.width}x${b.height} a${b.area}').join(' | ')}');
        }
      }
      if (bad) tiles.add(_tile(w.image, t, a, s1, label));
    }
  }
  for (var k = 0; k < tiles.length; k += 10) {
    final part = tiles.skip(k).take(10).toList();
    final sheet = img.Image(width: 640, height: 190 * part.length);
    for (var i = 0; i < part.length; i++) {
      img.compositeImage(sheet, part[i], dstY: i * 190);
    }
    File('${out.path}/angle_${k ~/ 10}.jpg')
        .writeAsBytesSync(img.encodeJpg(sheet, quality: 85));
  }
  for (final k in totals.keys.where((k) => !k.endsWith('/n'))) {
    stdout.writeln('$k: ${totals[k]}/${totals['$k/n']}');
  }
}

class _Result {
  _Result(this.area, this.snapped, this.seg);
  final NormalizedRect? area;
  final bool snapped;
  final PlateSegmentation? seg;
}

_Result _run(String path, NormalizedRect seed) {
  final snapped = snapCaptureAreaSync(path, seed);
  final area = snapped ?? seed;
  return _Result(area, snapped != null, segmentCaptureSync(path, area));
}

double _iou(NormalizedRect a, NormalizedRect b) {
  final w = math.min(a.right, b.right) - math.max(a.left, b.left);
  final h = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  if (w <= 0 || h <= 0) return 0;
  final i = w * h;
  return i / (a.width * a.height + b.width * b.height - i);
}

/// The photo turned by [yaw] about the plate's vertical centre line, in
/// perspective (the near side larger), from about three plate widths away.
class _Warp {
  _Warp(img.Image src, NormalizedRect plate, double yaw)
      : cx = plate.centerX * src.width,
        cy = plate.centerY * src.height,
        c = math.cos(yaw),
        s = math.sin(yaw),
        d = 3 * plate.width * src.width,
        sw = src.width,
        sh = src.height,
        image = img.Image(width: src.width, height: src.height) {
    for (var y = 0; y < sh; y++) {
      for (var x = 0; x < sw; x++) {
        // Inverse map: output (x, y) → source.
        final u2 = x - cx;
        final den = c - u2 * s / d;
        if (den <= 0.05) continue;
        final u = u2 / den;
        final k = 1 + u * s / d;
        final sx = cx + u, sy = cy + (y - cy) * k;
        if (sx < 0 || sy < 0 || sx >= sw - 1 || sy >= sh - 1) continue;
        image.setPixel(x, y, src.getPixelInterpolate(sx, sy));
      }
    }
  }

  final double cx, cy, c, s, d;
  final int sw, sh;
  final img.Image image;

  /// Where source point (x, y) (pixels) lands.
  (double, double) _fwd(double x, double y) {
    final u = x - cx, k = 1 + u * s / d;
    return (cx + u * c / k, cy + (y - cy) / k);
  }

  /// Bounding box of [r]'s corners after the turn.
  NormalizedRect rect(NormalizedRect r) {
    final pts = [
      for (final x in [r.left, r.right])
        for (final y in [r.top, r.bottom]) _fwd(x * sw, y * sh)
    ];
    double cl(double v) => v.clamp(0.0, 1.0);
    return NormalizedRect(
      cl(pts.map((p) => p.$1).reduce(math.min) / sw),
      cl(pts.map((p) => p.$2).reduce(math.min) / sh),
      cl(pts.map((p) => p.$1).reduce(math.max) / sw),
      cl(pts.map((p) => p.$2).reduce(math.max) / sh),
    );
  }
}

img.Image _tile(img.Image photo, NormalizedRect truth, NormalizedRect? area,
    PlateSegmentation? s, String label) {
  final view = area ?? truth;
  final l = math.min(view.left, truth.left), t = math.min(view.top, truth.top);
  final r = math.max(view.right, truth.right),
      b = math.max(view.bottom, truth.bottom);
  final pw = (r - l) * 0.15, ph = (b - t) * 0.4;
  final x0 = ((l - pw).clamp(0.0, 1.0) * photo.width).round();
  final y0 = ((t - ph).clamp(0.0, 1.0) * photo.height).round();
  final x1 = ((r + pw).clamp(0.0, 1.0) * photo.width).round();
  final y1 = ((b + ph).clamp(0.0, 1.0) * photo.height).round();
  var crop = img.copyCrop(photo, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  final scale = 160 / crop.height;
  crop = img.copyResize(crop, height: 160);
  void box(NormalizedRect q, img.Color c) => img.drawRect(crop,
      x1: ((q.left * photo.width - x0) * scale).round(),
      y1: ((q.top * photo.height - y0) * scale).round(),
      x2: ((q.right * photo.width - x0) * scale).round(),
      y2: ((q.bottom * photo.height - y0) * scale).round(),
      color: c);
  box(truth, img.ColorRgb8(255, 0, 0));
  if (area != null) {
    box(area, img.ColorRgb8(0, 255, 255));
    NormalizedRect sub(NormalizedRect q) => NormalizedRect(
        area.left + q.left * area.width,
        area.top + q.top * area.height,
        area.left + q.right * area.width,
        area.top + q.bottom * area.height);
    if (s != null) {
      for (final q in s.numberChars) {
        box(sub(q), img.ColorRgb8(255, 210, 0));
      }
      for (final q in s.latinStack) {
        box(sub(q), img.ColorRgb8(0, 220, 0));
      }
      for (final q in s.geezStack) {
        box(sub(q), img.ColorRgb8(220, 0, 220));
      }
      if (s.code != null) box(sub(s.code!), img.ColorRgb8(30, 120, 255));
    }
  }
  final tile = img.Image(width: 640, height: 190);
  img.drawString(tile, label, font: img.arial14, x: 4, y: 4);
  img.compositeImage(tile, crop.width > 640 ? img.copyResize(crop, width: 640) : crop,
      dstY: 26);
  return tile;
}
