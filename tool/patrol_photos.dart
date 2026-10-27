// Runs the patrol re-read's image steps (plate outline, sections) on every
// logged patrol vehicle photo, and draws what was found.
//
// dart run tool/patrol_photos.dart <et_plate_logs dir> <photos dir> <out dir>
//
// MIN_VOTES=3 (default) keeps well-read vehicles; SKIP=4 skips the first
// patrols (sample sheets on a screen).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';

void main(List<String> args) {
  final logs = Directory(args[0]), photos = args[1];
  final out = Directory(args[2])..createSync(recursive: true);
  final minVotes = int.parse(Platform.environment['MIN_VOTES'] ?? '3');
  final skip = int.parse(Platform.environment['SKIP'] ?? '4');
  final files = logs
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('patrol_'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  NormalizedRect r(Map m) => NormalizedRect((m['left'] as num).toDouble(),
      (m['top'] as num).toDouble(), (m['right'] as num).toDouble(),
      (m['bottom'] as num).toDouble());
  final summary = StringBuffer();
  final tiles = <img.Image>[];
  var n = 0, found = 0, twoRow = 0, latin2 = 0, circle = 0;
  for (final f in files.skip(skip)) {
    final log = jsonDecode(f.readAsStringSync()) as Map;
    for (final v in (log['vehicles'] as List).cast<Map>()) {
      if ((v['votes'] as int) < minVotes || v['photo'] == null) continue;
      final path = '$photos/${(v['photo'] as String).split('/').last}';
      if (!File(path).existsSync()) continue;
      n++;
      final b = r(v['box'] as Map);
      final h = b.height, w = b.width;
      double c(double x) => x.clamp(0.0, 1.0);
      // The logged box is the text band (or the re-read's area), possibly
      // shifted: search well around it.
      final seed = NormalizedRect(c(b.left - 1.0 * w), c(b.top - 2.5 * h),
          c(b.right + 0.6 * w), c(b.bottom + 2.5 * h));
      final area = snapCaptureAreaSync(path, seed);
      final seg = area == null ? null : segmentCaptureSync(path, area);
      if (area != null) found++;
      if (seg?.twoRow ?? false) twoRow++;
      if ((seg?.latinStack.length ?? 0) == 2) latin2++;
      if (seg?.code != null) circle++;
      final line = '${v['plate']} ${v['votes']}/${v['reads']} '
          'refined=${v['refined']} area=${area != null} '
          'twoRow=${seg?.twoRow} n=${seg?.numberChars.length} '
          'circle=${seg?.code != null} latin=${seg?.latinStack.length} '
          'geez=${seg?.geezStack.length} ${seg?.notes.lastOrNull ?? ''}';
      summary.writeln('${f.uri.pathSegments.last} $line');

      // Tile: the plate area (or the seed) with the sections drawn.
      final photo = img.decodeJpg(File(path).readAsBytesSync())!;
      final a = area ?? seed;
      final x = (a.left * photo.width).round(),
          y = (a.top * photo.height).round();
      final cw = math.max(10, (a.width * photo.width).round());
      final ch = math.max(10, (a.height * photo.height).round());
      final crop = img.copyResize(
          img.copyCrop(photo, x: x, y: y, width: cw, height: ch),
          height: 120);
      void box(NormalizedRect? q, img.Color col) {
        if (q == null) return;
        img.drawRect(crop,
            x1: (q.left * crop.width).round(),
            y1: (q.top * crop.height).round(),
            x2: (q.right * crop.width).round(),
            y2: (q.bottom * crop.height).round(),
            color: col);
      }

      if (seg != null) {
        box(seg.number, img.ColorRgb8(255, 220, 0));
        box(seg.code, img.ColorRgb8(0, 160, 255));
        for (final q in seg.latinStack) {
          box(q, img.ColorRgb8(0, 255, 0));
        }
        for (final q in seg.geezStack) {
          box(q, img.ColorRgb8(255, 0, 255));
        }
      }
      final t = img.Image(width: 400, height: 150);
      img.compositeImage(t,
          crop.width > 400 ? img.copyResize(crop, width: 400) : crop,
          dstY: 26);
      img.drawString(
          t,
          '${tiles.length} ${v['plate']} ${seg?.twoRow == true ? '2row' : ''}'
          '${area == null ? ' NOAREA' : ''}',
          font: img.arial14,
          x: 4,
          y: 4);
      tiles.add(t);
    }
  }
  for (var i = 0; i < tiles.length; i += 24) {
    final sheet = img.Image(width: 1200, height: 150 * 8);
    for (var j = 0; j < 24 && i + j < tiles.length; j++) {
      img.compositeImage(sheet, tiles[i + j],
          dstX: (j % 3) * 400, dstY: (j ~/ 3) * 150);
    }
    File('${out.path}/sheet_${(i ~/ 24).toString().padLeft(2, '0')}.jpg')
        .writeAsBytesSync(img.encodeJpg(sheet, quality: 85));
  }
  File('${out.path}/summary.txt').writeAsStringSync(summary.toString());
  stdout.writeln('$n vehicles: plate found $found, two-row $twoRow, '
      'latin pair $latin2, circle $circle');
}
