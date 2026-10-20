// Draws the image-based plate segmentation for every logged session.
//
// dart run tool/segment_logs.dart <et_plate_logs dir> <out dir>
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';

void main(List<String> args) {
  final dir = Directory(args[0]);
  final out = Directory(args[1])..createSync(recursive: true);
  final segmenter = PlateSegmenter();
  final tiles = <img.Image>[];
  final summary = StringBuffer();

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final only = Platform.environment['ONLY']?.split(',');
  for (final f in files) {
    if (only != null && !only.any((id) => f.path.contains(id))) continue;
    final log = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final events = (log['events'] as List).cast<Map<String, dynamic>>();
    final ca = events.where((e) => e['event'] == 'confirmArea').lastOrNull;
    final jpg = File(f.path.replaceAll('.json', '.jpg'));
    if (ca == null || !jpg.existsSync()) continue;
    final photo = img.decodeJpg(jpg.readAsBytesSync())!;
    final a = (ca['area'] as Map).cast<String, num>();
    final x = (a['left']! * photo.width).round(),
        y = (a['top']! * photo.height).round();
    final cw = ((a['right']! - a['left']!) * photo.width).round();
    final ch = ((a['bottom']! - a['top']!) * photo.height).round();
    if (cw < 10 || ch < 10) continue;
    final crop = img.copyCrop(photo, x: x, y: y, width: cw, height: ch);
    final plate = img.copyResize(crop,
        height: 160, interpolation: img.Interpolation.average);
    final gray = GrayImage(
      plate.width,
      plate.height,
      img
          .grayscale(img.Image.from(plate))
          .getBytes(order: img.ChannelOrder.red),
    );
    final s = segmenter.segment(gray);

    void box(NormalizedRect r, img.Color c, [int t = 2]) {
      for (var k = 0; k < t; k++) {
        img.drawRect(plate,
            x1: (r.left * plate.width).round() - k,
            y1: (r.top * plate.height).round() - k,
            x2: (r.right * plate.width).round() + k,
            y2: (r.bottom * plate.height).round() + k,
            color: c);
      }
    }

    for (final c in s.columns) {
      box(
          NormalizedRect(c.box.left / plate.width, c.box.top / plate.height,
              c.box.right / plate.width, c.box.bottom / plate.height),
          img.ColorRgb8(150, 150, 150),
          1);
    }
    for (final r in s.numberChars) {
      box(r, img.ColorRgb8(240, 190, 0));
    }
    for (final r in s.latinStack) {
      box(r, img.ColorRgb8(0, 180, 0));
    }
    for (final r in s.geezStack) {
      box(r, img.ColorRgb8(170, 60, 200));
    }
    for (final r in s.leftDigits) {
      box(r, img.ColorRgb8(255, 120, 0));
    }
    if (s.code != null) box(s.code!, img.ColorRgb8(30, 120, 255));

    final id = (log['session'] as String);
    final label =
        '${id.substring(id.length - 5)} n=${s.numberChars.length} lat=${s.latinStack.length} gz=${s.geezStack.length} code=${s.code != null ? 1 : 0} left=${s.leftDigits.length} word=${s.leftWord.length}${s.latinSideBySide ? ' side' : ''}';
    summary.writeln(
        '$label  cols=${s.columns.map((c) => c.kind == ColumnKind.short ? '.' : c.kind.name[0]).join()}  ${s.notes.join(' ')}');
    if (Platform.environment['COLS'] != null) {
      for (final c in s.columns) {
        summary.writeln(
            '    ${c.kind.name.padRight(6)} ${c.blobs.map((b) => '${b.left},${b.top} ${b.width}x${b.height} a${b.area}').join(' | ')}');
      }
    }
    final tile = img.Image(width: 640, height: 190);
    img.fill(tile, color: img.ColorRgb8(255, 255, 255));
    img.drawString(tile, label,
        font: img.arial14, x: 4, y: 4, color: img.ColorRgb8(0, 0, 0));
    img.compositeImage(tile,
        img.copyResize(plate, width: plate.width > 640 ? 640 : plate.width),
        dstY: 26);
    tiles.add(tile);
  }
  for (var k = 0; k < tiles.length; k += 10) {
    final part = tiles.skip(k).take(10).toList();
    final sheet = img.Image(width: 640, height: 190 * part.length);
    for (var i = 0; i < part.length; i++) {
      img.compositeImage(sheet, part[i], dstY: i * 190);
    }
    File('${out.path}/seg_${k ~/ 10}.png')
        .writeAsBytesSync(img.encodePng(sheet));
  }
  stdout.write(summary);
}
