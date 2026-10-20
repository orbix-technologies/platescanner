// Snaps the proposed plate area of every logged session to the plate outline
// and draws proposed (red), confirmed (green) and snapped (cyan) boxes.
//
// dart run tool/area_logs.dart <et_plate_logs dir> <out dir>
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/plate_bounds_finder.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';

void main(List<String> args) {
  final dir = Directory(args[0]);
  final out = Directory(args[1])..createSync(recursive: true);
  final only = Platform.environment['ONLY']?.split(',');
  const finder = PlateBoundsFinder();
  final tiles = <img.Image>[];
  final summary = StringBuffer();
  var n = 0, snapped = 0;
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    if (only != null && !only.any((id) => f.path.contains(id))) continue;
    final log = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final events = (log['events'] as List).cast<Map<String, dynamic>>();
    final cap = events.where((e) => e['event'] == 'capture').lastOrNull;
    final ca = events.where((e) => e['event'] == 'confirmArea').lastOrNull;
    final done = events.where((e) => e['event'] == 'done').lastOrNull;
    final jpg = File(f.path.replaceAll('.json', '.jpg'));
    if (cap == null || ca == null || !jpg.existsSync()) continue;
    if (cap['proposed'] == null) continue;
    final record = (done?['record'] as String?) ?? '';
    if (record.isNotEmpty && !'12345'.contains(record[0])) continue;
    final photo = img.decodeJpg(jpg.readAsBytesSync())!;
    final gray = GrayImage(
      photo.width,
      photo.height,
      img
          .grayscale(img.Image.from(photo))
          .getBytes(order: img.ChannelOrder.red),
    );
    NormalizedRect rect(Object? m) {
      final a = (m as Map).cast<String, num>();
      return NormalizedRect(a['left']!.toDouble(), a['top']!.toDouble(),
          a['right']!.toDouble(), a['bottom']!.toDouble());
    }

    final seed = rect(cap['proposed']);
    final confirmed = rect(ca['area']);
    final sw = Stopwatch()..start();
    final detected = cap['detected'] == null ? null : rect(cap['detected']);
    final bounds = finder.findDetailed(gray, seed) ??
        (detected == null || detected == seed
            ? null
            : finder.findDetailed(gray, detected));
    final found = bounds?.area;
    final ms = sw.elapsedMilliseconds;
    n++;
    if (found != null) snapped++;
    final id = f.uri.pathSegments.last.replaceAll(RegExp(r'\D'), '');
    String fmt(NormalizedRect? r) => r == null
        ? '-'
        : '(${r.left.toStringAsFixed(3)} ${r.top.toStringAsFixed(3)} '
            '${r.right.toStringAsFixed(3)} ${r.bottom.toStringAsFixed(3)})';
    summary.writeln('$id $record seed ${fmt(seed)} confirmed ${fmt(confirmed)}'
        ' snapped ${fmt(found)} edges ${bounds == null ? '-' : [
            bounds.topEdge,
            bounds.bottomEdge,
            bounds.leftEdge,
            bounds.rightEdge
          ].map((e) => e ? 'y' : 'n').join()} ${ms}ms');

    void box(NormalizedRect r, img.Color c, int t) {
      for (var k = 0; k < t; k++) {
        img.drawRect(photo,
            x1: (r.left * photo.width).round() - k,
            y1: (r.top * photo.height).round() - k,
            x2: (r.right * photo.width).round() + k,
            y2: (r.bottom * photo.height).round() + k,
            color: c);
      }
    }

    box(seed, img.ColorRgb8(255, 0, 0), 4);
    box(confirmed, img.ColorRgb8(0, 255, 0), 2);
    if (bounds != null) {
      if (Platform.environment['SHAPES'] != null) {
        for (final r in bounds.shapes) {
          box(r, img.ColorRgb8(255, 0, 255), 1);
        }
      }
      box(bounds.serial, img.ColorRgb8(255, 220, 0), 1);
      box(bounds.area, img.ColorRgb8(0, 255, 255), 2);
    }

    // Tile around the boxes.
    var u = seed.union(confirmed);
    if (found != null) u = u.union(found);
    final ux0 = u.left * photo.width, ux1 = u.right * photo.width;
    final uy0 = u.top * photo.height, uy1 = u.bottom * photo.height;
    final pad = 0.08 * (ux1 - ux0);
    final x = math.max(0, ux0 - pad).round(),
        y = math.max(0, uy0 - pad).round();
    final crop = img.copyCrop(photo,
        x: x,
        y: y,
        width: math.min(photo.width - x, (ux1 - ux0 + 2 * pad).round()),
        height: math.min(photo.height - y, (uy1 - uy0 + 2 * pad).round()));
    final t = img.Image(width: 600, height: 320);
    final fit = img.copyResize(crop,
        width: crop.width / crop.height > 600 / 300 ? 600 : null,
        height: crop.width / crop.height > 600 / 300 ? null : 300);
    img.compositeImage(t, fit, dstX: 0, dstY: 20);
    img.drawString(t, '$id $record', font: img.arial14, x: 4, y: 2);
    tiles.add(t);
  }
  for (var i = 0; i < tiles.length; i += 12) {
    final sheet = img.Image(width: 1200, height: 320 * 6);
    for (var j = 0; j < 12 && i + j < tiles.length; j++) {
      img.compositeImage(sheet, tiles[i + j],
          dstX: (j % 2) * 600, dstY: (j ~/ 2) * 320);
    }
    File('${out.path}/sheet_${(i ~/ 12).toString().padLeft(2, '0')}.jpg')
        .writeAsBytesSync(img.encodeJpg(sheet, quality: 80));
  }
  File('${out.path}/summary.txt').writeAsStringSync(summary.toString());
  stdout.writeln('$n sessions, snapped $snapped');
}
