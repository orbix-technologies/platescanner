import 'dart:math' as math;
import 'dart:typed_data';

import '../models/ocr_frame.dart';
import 'plate_segmenter.dart';

/// Step 1b: snaps a rough plate area to the plate itself on the still.
///
/// The live area comes from OCR text on a preview frame plus fixed margins:
/// it is loose, sometimes from a frame before the still was shot, and cuts
/// letters OCR did not read. On the still the finder:
///
/// 1. finds the serial — a row of four or more dark shapes of the same
///    height, evenly spaced (the digits) — nearest the seed;
/// 2. takes the plate's top and bottom from the long horizontal edges just
///    outside that row (plate edge / printed border), following its tilt;
/// 3. takes left and right from the first vertical edge, going outwards,
///    that spans the plate's whole height including the margins above and
///    below the row (text never does), near where the top and bottom edges
///    end and within what the 1–5 layout allows (circle and Ge'ez left of
///    the digits, the stacked letters right of them).
///
/// A side without an edge falls back to where the top / bottom edges end,
/// or the layout's proportions.
class PlateBoundsFinder {
  /// Creates a finder.
  const PlateBoundsFinder();

  /// Seed height in working pixels.
  static const _seedPx = 170.0;

  /// Plate area around [seed] (normalized to [image]), or `null` when no
  /// serial row is found (keep the seed then).
  NormalizedRect? find(GrayImage image, NormalizedRect seed) =>
      findDetailed(image, seed)?.area;

  /// [find] with the intermediate results (tools, tests).
  PlateBounds? findDetailed(GrayImage image, NormalizedRect seed) {
    final iw = image.width, ih = image.height;
    final sw = seed.width * iw, sh = seed.height * ih;
    if (sw < 20 || sh < 8) return null;

    // Search window: the seed may be shifted by a stale frame, cut a stack
    // or be twice the plate's height, so look well beyond it.
    final winW = sw * 1.7, winH = math.max(sh * 2.4, sw * 0.6);
    final x0 = (seed.centerX * iw - winW / 2).clamp(0.0, iw - 1.0);
    final y0 = (seed.centerY * ih - winH / 2).clamp(0.0, ih - 1.0);
    final x1 = (seed.centerX * iw + winW / 2).clamp(1.0, iw.toDouble());
    final y1 = (seed.centerY * ih + winH / 2).clamp(1.0, ih.toDouble());
    var scale = _seedPx / sh;
    if ((x1 - x0) * scale > 1200) scale = 1200 / (x1 - x0);
    final w = ((x1 - x0) * scale).round(), h = ((y1 - y0) * scale).round();
    if (w < 40 || h < 30) return null;
    final g = _resample(image, x0, y0, x1, y1, w, h);

    final seedCx = (seed.centerX * iw - x0) * scale;
    final seedCy = (seed.centerY * ih - y0) * scale;
    final seedW = sw * scale, seedH = sh * scale;

    final shapes = <_Box>[];
    final ink = _inkMask(g, w, h, (seedH * 0.35).round().clamp(8, 60));
    final row = _serialRow(ink, w, h, seedCx, seedCy, seedW, seedH, shapes);
    if (row == null) return null;

    final gy = _sobelY(g, w, h), gx = _sobelX(g, w, h);
    final thrY = math.max(40.0, _percentile(gy, 0.85) * 0.5);
    final thrX = math.max(40.0, _percentile(gx, 0.85) * 0.5);
    final rh = row.height;
    // Old two-row plate: the region row above the digits; the plate's top
    // edge is above that row.
    final upperRow = _upperRow(ink, w, h, row);
    final upper = upperRow?.top;
    final twoRow = upperRow != null;
    final topLine = _border(gy, w, h, thrY, row, above: true, base: upper ?? 0);
    final bottomLine = _border(gy, w, h, thrY, row, above: false);
    final top = topLine ?? (upper ?? 0) - 0.2 * rh;
    final bottom = bottomLine ?? 0.2 * rh;

    // Left / right, within the layout's limits (in digit pitches): a
    // two-row plate's number spans nearly its whole width.
    final p = row.pitch;
    final minL = row.left - (twoRow ? 1.2 : 4.6) * p;
    final maxL = row.left - (twoRow ? 0.1 : 1.0) * p;
    final minR = row.right + (twoRow ? 0.1 : 0.45) * p;
    final maxR = row.right + (twoRow ? 1.0 : 1.8) * p;
    // Where the top / bottom edges end: the sides are there, so a side
    // well short of both is text or a screw, not the plate's.
    double? runLeft, runRight, outerLeft, outerRight;
    for (final off in [
      if (topLine != null) row.top + topLine,
      if (bottomLine != null) row.bottom + bottomLine,
    ]) {
      final (l, r) = _runEnds(gy, w, h, thrY, row, off);
      runLeft = runLeft == null ? l : math.max(runLeft, l);
      runRight = runRight == null ? r : math.min(runRight, r);
      outerLeft = outerLeft == null ? l : math.min(outerLeft, l);
      outerRight = outerRight == null ? r : math.max(outerRight, r);
    }
    final fromL = math.min(maxL, (runLeft ?? maxL) + 0.3 * rh);
    // Right: from just inside the row's end (a stack joined by a screw can
    // end the row past the stack), the first plate-high edge; the
    // strongest may be the bumper beyond.
    final fromR =
        math.max(row.right - 1.2 * p, (runRight ?? row.right) - 0.3 * rh);
    var leftX = _side(gx, w, h, thrX, row, top, bottom, fromL, minL);
    var rightX = _side(gx, w, h, thrX, row, top, bottom, fromR, maxR);
    final leftEdge = leftX != null, rightEdge = rightX != null;
    final guessL = row.left - (twoRow ? 0.4 : 3.2) * p;
    final guessR = row.right + (twoRow ? 0.4 : 1.2) * p;
    leftX ??= (outerLeft ?? guessL).clamp(minL, maxL);
    rightX ??= (outerRight ?? guessR).clamp(minR, math.max(minR, guessR));
    // Plate width is 3.3–5.2 times its height (two-row: 1.5–2.8); trust a
    // found edge over a guessed one.
    final plateH = row.height + bottom - top;
    final maxAspect = twoRow ? 2.8 : 5.2, minAspect = twoRow ? 1.5 : 3.3;
    var left = leftX, right = rightX;
    // The region row spans the plate: circle at its left, letters at its
    // right (the number row may have missed a character).
    if (upperRow != null) {
      left = math.min(left, upperRow.left - 0.15 * rh);
      right = math.max(right, upperRow.right + 0.15 * rh);
    }
    if (right - left > maxAspect * plateH) {
      if (!leftEdge || rightEdge) {
        left = math.max(left, right - maxAspect * plateH);
      }
      if (right - left > maxAspect * plateH) right = left + maxAspect * plateH;
    } else if (right - left < minAspect * plateH) {
      if (!leftEdge) left = math.max(minL, right - minAspect * plateH);
    }

    // Corners along the row's tilt.
    final ys = [
      for (final x in [left, right]) ...[
        row.yTop(x) + top,
        row.yBottom(x) + bottom,
      ]
    ];
    final mx = 0.12 * rh, my = 0.06 * rh;
    double nx(double v) => ((v / scale + x0) / iw).clamp(0.0, 1.0);
    double ny(double v) => ((v / scale + y0) / ih).clamp(0.0, 1.0);
    NormalizedRect rect(double l, double t, double r, double b) =>
        NormalizedRect(nx(l), ny(t), nx(r), ny(b));
    return PlateBounds(
      area: rect(left - mx, ys.reduce(math.min) - my, right + mx,
          ys.reduce(math.max) + my),
      serial: rect(row.left, row.top, row.right, row.bottom),
      shapes: [
        for (final b in shapes)
          rect(b.left.toDouble(), b.top.toDouble(), b.right.toDouble(),
              b.bottom.toDouble())
      ],
      twoRow: twoRow,
      topEdge: topLine != null,
      bottomEdge: bottomLine != null,
      leftEdge: leftEdge,
      rightEdge: rightEdge,
    );
  }

  /// The row of same-height dark shapes nearest the seed centre.
  static _Row? _serialRow(Uint8List ink, int w, int h, double seedCx,
      double seedCy, double seedW, double seedH, List<_Box> blobs) {
    for (final b in _components(ink, w, h)) {
      final bh = b.height, bw = b.width;
      if (bh < 0.1 * seedH || bh > 1.0 * seedH) continue;
      if (bw < 0.08 * bh || bw > 0.95 * bh) continue;
      final fill = b.area / (bw * bh);
      if (fill < 0.12 || fill > 0.92) continue;
      if (b.left == 0 || b.top == 0 || b.right == w || b.bottom == h) continue;
      if (_waisted(ink, w, b.left, b.right - 1, b.top, b.bottom - 1)) continue;
      blobs.add(b);
    }
    blobs.sort((a, b) => a.left.compareTo(b.left));

    _Row? best;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < blobs.length; i++) {
      final members = [blobs[i]];
      final ref = blobs[i].height.toDouble();
      // Line of the last shape that matched top and bottom; a screw or
      // rivet touching a digit leaves only one side on the line.
      var refTop = blobs[i].top.toDouble(), refBottom = blobs[i].bottom;
      var refX = blobs[i].centerX;
      // Tilt so far (from the first to the last matched shape), so a
      // tilted plate's row is followed; limited to ~11°.
      var slope = 0.0;
      for (var j = i + 1; j < blobs.length; j++) {
        final prev = members.last, b = blobs[j];
        if (b.left < prev.right - 0.1 * ref) continue;
        if (b.left - prev.right > 1.3 * ref) break;
        final shift = slope * (b.centerX - refX);
        final topOk = (b.top - refTop - shift).abs() <= 0.15 * ref;
        final bottomOk = (b.bottom - refBottom - shift).abs() <= 0.15 * ref;
        if (topOk && bottomOk) {
          refTop = b.top.toDouble();
          refBottom = b.bottom;
          refX = b.centerX;
          final first = members.first;
          slope = ((b.top + b.bottom - first.top - first.bottom) /
                  2 /
                  (b.centerX - first.centerX))
              .clamp(-0.2, 0.2);
        } else if (!(topOk && b.bottom > refBottom && b.height < 1.6 * ref) &&
            !(bottomOk && b.top < refTop && b.height < 1.6 * ref)) {
          continue;
        }
        members.add(b);
      }
      if (members.length < 4) continue;
      final row = _Row(members);
      // Evenly spaced: the digits share one pitch.
      final gaps = [
        for (var k = 1; k < members.length; k++)
          members[k].centerX - members[k - 1].centerX
      ]..sort();
      final pitch = gaps[gaps.length ~/ 2];
      if (gaps.last > 2.4 * pitch) continue;
      final dx = ((row.left + row.right) / 2 - seedCx).abs() / seedW;
      final dy = ((row.top + row.bottom) / 2 - seedCy).abs() / seedH;
      final score = members.length - 4 * dx - 6 * dy;
      if (score > bestScore) {
        bestScore = score;
        best = row;
      }
    }
    if (best != null) {
      best.right = _extend(ink, w, h, best, 1);
      best.left = _extend(ink, w, h, best, -1);
    }
    return best;
  }

  /// Extends the row past digits its shapes missed (joined to a screw or
  /// the border): the next character-wide run of columns inked across the
  /// row's middle and most of its height. Stops at a gap or at a stack
  /// (stacked letters leave the middle blank). Returns the new end.
  static double _extend(Uint8List ink, int w, int h, _Row row, int dir) {
    final rh = row.height;
    bool inked(int x, double from, double to) {
      if (x < 0 || x >= w) return false;
      final y0 = (row.yTop(x) + from * rh).round().clamp(0, h - 1);
      final y1 = (row.yTop(x) + to * rh).round().clamp(0, h - 1);
      for (var y = y0; y <= y1; y++) {
        if (ink[y * w + x] == 1) return true;
      }
      return false;
    }

    // A digit has ink on (nearly) every row of the band; two stacked
    // letters leave a blank stripe between them.
    bool digitLike(int xa, int xb) {
      final y0 = row.yTop((xa + xb) / 2).round();
      final n = rh.round();
      var covered = 0, blank = 0, longestBlank = 0;
      for (var k = 0; k < n; k++) {
        final y = y0 + k;
        var on = false;
        if (y >= 0 && y < h) {
          for (var x = xa; x <= xb && !on; x++) {
            on = ink[y * w + x] == 1;
          }
        }
        if (on) {
          covered++;
          blank = 0;
        } else if (k > 0.2 * n && k < 0.8 * n) {
          longestBlank = math.max(longestBlank, ++blank);
        }
      }
      return covered >= 0.8 * n &&
          longestBlank < math.max(2, 0.04 * n) &&
          !_waisted(ink, w, xa, xb, math.max(0, y0), math.min(h - 1, y0 + n));
    }

    var end = (dir > 0 ? row.right : row.left).round();
    while (true) {
      // Gap up to the next character. Ink above or below with the middle
      // blank for a while is a stack (or the circle's ring): stop there.
      var x = end + dir, gap = 0;
      int? firstInk;
      while (true) {
        if (x <= 0 || x >= w - 1) return end.toDouble();
        if (inked(x, 0.4, 0.6)) break;
        if (inked(x, 0.05, 0.95)) {
          firstInk ??= x;
          if ((x - firstInk).abs() > 0.3 * rh) return end.toDouble();
        } else if (firstInk == null && ++gap > 0.7 * rh) {
          return end.toDouble();
        }
        x += dir;
      }
      final start = firstInk ?? x;
      // The character: columns inked anywhere over the row's height.
      while (x > 0 &&
          x < w - 1 &&
          (inked(x, 0.05, 0.95) || inked(x + dir, 0.05, 0.95))) {
        x += dir;
      }
      final segW = (x - start).abs();
      // Up to two characters wide: neighbours joined by a screw or blur.
      if (segW < 0.12 * rh || segW > 2.1 * rh) return end.toDouble();
      final xa = math.min(start, x - dir), xb = math.max(start, x - dir);
      if (!digitLike(xa, xb)) return end.toDouble();
      final other = dir > 0 ? row.left : row.right;
      if ((x - dir - other).abs() > 7.5 * row.pitch) return end.toDouble();
      end = x - dir;
    }
  }

  /// Offset (from the row's top, negative, or bottom, positive) of the
  /// plate edge above / below the row: the line just outside the digits
  /// that a same-sign vertical gradient covers along the row's whole width.
  /// Prefers the outer of two strong lines (plate edge over printed
  /// border). `null` when none covers enough.
  static double? _border(Float32List gy, int w, int h, double thr, _Row row,
      {required bool above, double base = 0}) {
    final rh = row.height;
    final cov = <int, double>{};
    final dMin = (0.03 * rh).round(), dMax = (0.36 * rh).round();
    for (var d = dMin; d <= dMax; d++) {
      final off = base + (above ? -d : d);
      var pos = 0, neg = 0, n = 0;
      for (var x = row.left.round(); x <= row.right.round(); x++) {
        final yb = (above ? row.yTop(x) : row.yBottom(x)) + off;
        final y = yb.round();
        if (y < 1 || y >= h - 1 || x < 0 || x >= w) continue;
        n++;
        final a = gy[y * w + x],
            b = gy[(y + 1) * w + x],
            c = gy[(y - 1) * w + x];
        if (a > thr || b > thr || c > thr) pos++;
        if (a < -thr || b < -thr || c < -thr) neg++;
      }
      if (n > 0) cov[d] = math.max(pos, neg) / n;
    }
    if (cov.isEmpty) return null;
    var bestD = cov.keys.first;
    for (final d in cov.keys) {
      if (cov[d]! > cov[bestD]!) bestD = d;
    }
    final bestCov = cov[bestD]!;
    if (bestCov < 0.55) return null;
    // An outer line nearly as strong is the plate edge.
    var chosen = bestD;
    for (var d = bestD + 1; d <= math.min(dMax, bestD + 0.1 * rh); d++) {
      if ((cov[d] ?? 0) >= 0.85 * bestCov) chosen = d;
    }
    return base + (above ? -chosen : chosen);
  }

  /// An old two-row plate's region row: four or more letter-sized shapes
  /// (0.35–0.85 of a digit) level with each other (along the digits' tilt)
  /// just above the digits. Screws and the chip above a one-row plate are
  /// smaller and fewer. Returns its top as an offset (negative) from the
  /// row's top, and its left / right ends; null on one-row plates.
  static ({double top, double left, double right})? _upperRow(
      Uint8List ink, int w, int h, _Row row) {
    final rh = row.height;
    // Worked on straightened along the row's tilt (each column shifted so
    // the row is level), so the border above is level too.
    double level(_Box b, num y) => y.toDouble();
    double centre(_Box b) => level(b, (b.top + b.bottom) / 2);
    // The region row sits against the plate's top border: at small sizes
    // its letters touch the border line and form one wide shape. Long
    // horizontal runs of ink (the border; no letter is that wide) are
    // cleared from the straightened copy first; on a tilted plate the
    // border would otherwise break into short slanted runs that stay.
    final clean = Uint8List(w * h);
    for (var x = 0; x < w; x++) {
      final d = (row.yTop(x.toDouble()) - row.top).round();
      for (var y = 0; y < h; y++) {
        final sy = y + d;
        if (sy >= 0 && sy < h) clean[y * w + x] = ink[sy * w + x];
      }
    }
    final maxRun = (1.2 * rh).round();
    for (var y = 0; y < h; y++) {
      var start = -1;
      for (var x = 0; x <= w; x++) {
        final on = x < w && clean[y * w + x] == 1;
        if (on && start < 0) start = x;
        if (!on && start >= 0) {
          if (x - start > maxRun) clean.fillRange(y * w + start, y * w + x, 0);
          start = -1;
        }
      }
    }
    // A digit-high shape ending just above the row: the number of another
    // plate stacked above (whose stacked letters' lower halves would pass
    // for a region row).
    final comps = _components(clean, w, h);
    if (comps.any((b) =>
        b.height >= 0.85 * rh &&
        b.width >= 0.3 * rh &&
        b.width <= b.height * 1.3 &&
        level(b, b.bottom) <= row.top - 0.02 * rh &&
        level(b, b.bottom) >= row.top - 0.9 * rh &&
        b.right >= row.left &&
        b.left <= row.right)) {
      return null;
    }
    // Letter-high shapes just above the row. Small or seen at an angle,
    // neighbouring letters (the circle and the Ge'ez pair) touch and form
    // one wide shape: it counts as the letters it spans.
    final above = [
      for (final b in comps)
        if (level(b, b.bottom) <= row.top - 0.02 * rh &&
            level(b, b.bottom) >= row.top - 0.9 * rh &&
            b.height >= 0.35 * rh &&
            b.height <= 0.85 * rh &&
            b.width <= b.height * 4.5 &&
            b.left >= row.left - 2.5 * rh &&
            b.right <= row.right + 2.5 * rh)
          b,
    ];
    int count(_Box b) => math.max(1, (b.width / (b.height * 0.9)).round());
    if (above.length < 2 || above.map(count).fold(0, (a, b) => a + b) < 4) {
      return null;
    }
    final centres = [for (final b in above) centre(b)]..sort();
    final mid = centres[centres.length ~/ 2];
    final letters = [
      for (final b in above)
        if ((centre(b) - mid).abs() <= 0.25 * rh) b,
    ];
    if (letters.length < 2 || letters.map(count).fold(0, (a, b) => a + b) < 4) {
      return null;
    }
    // Region letters are about half a digit high (the circle a little
    // more); a row of shapes two-thirds as high is the number of another
    // plate above.
    final hs = [for (final b in letters) b.height]..sort();
    if (hs[hs.length ~/ 2] > 0.65 * rh) return null;
    // Six or more alike (circle, two Ge'ez, two Latin and a smaller chip
    // make five): the digits of another plate above.
    final typical = hs[hs.length ~/ 2];
    final alike = letters.where((b) =>
        (b.height - typical).abs() <= typical * 0.15 &&
        b.width <= b.height * 1.3);
    if (alike.length >= 6) return null;
    return (
      top: letters.map((b) => level(b, b.top)).reduce(math.min) - row.top,
      left: letters.map((b) => b.left).reduce(math.min).toDouble(),
      right: letters.map((b) => b.right).reduce(math.max).toDouble(),
    );
  }

  /// Where the edge at [off] (from the row's top / bottom) ends left and
  /// right of the digits, allowing small breaks (screws, glare).
  static (double, double) _runEnds(
      Float32List gy, int w, int h, double thr, _Row row, double off) {
    final above = off < (row.top + row.bottom) / 2;
    final d = above ? off - row.top : off - row.bottom;
    bool hit(int x) {
      final y = ((above ? row.yTop(x) : row.yBottom(x)) + d).round();
      if (y < 2 || y >= h - 2) return false;
      for (var k = -2; k <= 2; k++) {
        if (gy[(y + k) * w + x].abs() > thr) return true;
      }
      return false;
    }

    final maxGap = (0.25 * row.height).round();
    double end(int dir) {
      var x = dir < 0 ? row.left.round() : row.right.round();
      var last = x, gap = 0;
      while (x > 0 && x < w - 1 && gap <= maxGap) {
        x += dir;
        if (hit(x)) {
          last = x;
          gap = 0;
        } else {
          gap++;
        }
      }
      return last.toDouble();
    }

    return (end(-1), end(1));
  }

  /// The plate's side between [from] (inside) and [to] (outside): the
  /// first vertical edge spanning the plate's height (between the row's top
  /// + [top] and bottom + [bottom], along its tilt), moved to an outer one
  /// nearly as strong close by (the plate edge outside its printed border).
  /// Text never spans the plate's height, so it is never taken. `null` when
  /// no edge covers enough.
  static double? _side(Float32List gx, int w, int h, double thr, _Row row,
      double top, double bottom, double from, double to) {
    final rh = row.height;
    final dir = to > from ? 1 : -1;
    double? bestX;
    var best = 0.75;
    for (var x = from.round();
        dir > 0 ? x <= to.round() : x >= to.round();
        x += dir) {
      if (x < 1 || x > w - 2) break;
      if (bestX != null && (x - bestX).abs() > 0.1 * rh) break;
      // The plate's whole height, and on its own the margin above and
      // below the row, where an edge of the plate runs and text does not.
      final ya = row.yTop(x) + top + 0.03 * rh;
      final yb = row.yBottom(x) + bottom - 0.03 * rh;
      final ma = row.yTop(x) + 0.4 * top, mb = row.yBottom(x) + 0.4 * bottom;
      final yc = (ya + yb) / 2;
      // Sides lean with the plate's rotation and perspective.
      var cov = 0.0;
      for (var lean = -0.16; lean <= 0.161; lean += 0.02) {
        var pos = 0, neg = 0, n = 0;
        var mPos = 0, mNeg = 0, mn = 0;
        for (var y = math.max(1, ya.round());
            y <= math.min(h - 2, yb.round());
            y++) {
          final xx = (x + (y - yc) * lean).round();
          if (xx < 1 || xx >= w - 1) continue;
          final margin = y <= ma || y >= mb;
          n++;
          if (margin) mn++;
          final i = y * w + xx;
          final a = gx[i], b = gx[i - 1], c = gx[i + 1];
          if (a > thr || b > thr || c > thr) {
            pos++;
            if (margin) mPos++;
          }
          if (a < -thr || b < -thr || c < -thr) {
            neg++;
            if (margin) mNeg++;
          }
        }
        if (n < 5 || mn < 2) continue;
        if (math.max(mPos, mNeg) / mn < 0.6) continue;
        cov = math.max(cov, math.max(pos, neg) / n);
      }
      if (cov > best) best = cov;
      if (cov >= (bestX == null ? best : 0.85 * best)) bestX = x.toDouble();
    }
    return bestX;
  }

  /// Whether the ink in the box narrows to a thin neck in its middle: two
  /// stacked letters touching. A digit's middle rows always hold a stroke
  /// a good part of its width.
  static bool _waisted(Uint8List ink, int w, int xa, int xb, int ya, int yb) {
    final bw = xb - xa + 1, bh = yb - ya + 1;
    final limit = math.max(1, 0.15 * bw);
    for (var y = ya + (0.3 * bh).round(); y <= ya + (0.7 * bh).round(); y++) {
      var c = 0;
      for (var x = xa; x <= xb; x++) {
        c += ink[y * w + x];
      }
      if (c <= limit) return true;
    }
    return false;
  }

  /// Dark pixels against the local mean (Bradley).
  static Uint8List _inkMask(Float32List g, int w, int h, int r) {
    final integral = Float64List((w + 1) * (h + 1));
    for (var y = 0; y < h; y++) {
      var rowSum = 0.0;
      for (var x = 0; x < w; x++) {
        rowSum += g[y * w + x];
        integral[(y + 1) * (w + 1) + x + 1] =
            integral[y * (w + 1) + x + 1] + rowSum;
      }
    }
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final ya = math.max(0, y - r), yb = math.min(h, y + r + 1);
      for (var x = 0; x < w; x++) {
        final xa = math.max(0, x - r), xb = math.min(w, x + r + 1);
        final sum = integral[yb * (w + 1) + xb] -
            integral[ya * (w + 1) + xb] -
            integral[yb * (w + 1) + xa] +
            integral[ya * (w + 1) + xa];
        final mean = sum / ((xb - xa) * (yb - ya));
        if (g[y * w + x] < mean * 0.82) out[y * w + x] = 1;
      }
    }
    return out;
  }

  /// 8-connected components of [mask].
  static List<_Box> _components(Uint8List mask, int w, int h) {
    final seen = Uint8List(w * h);
    final stack = <int>[];
    final out = <_Box>[];
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0 || seen[i] == 1) continue;
      var l = w, t = h, r = 0, b = 0, area = 0;
      seen[i] = 1;
      stack.add(i);
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final x = p % w, y = p ~/ w;
        area++;
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            final q = yy * w + xx;
            if (mask[q] == 1 && seen[q] == 0) {
              seen[q] = 1;
              stack.add(q);
            }
          }
        }
      }
      out.add(_Box(l, t, r + 1, b + 1, area));
    }
    return out;
  }

  static Float32List _sobelY(Float32List g, int w, int h) {
    final gy = Float32List(w * h);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        gy[i] = (g[i + w - 1] + 2 * g[i + w] + g[i + w + 1]) -
            (g[i - w - 1] + 2 * g[i - w] + g[i - w + 1]);
      }
    }
    return gy;
  }

  static Float32List _sobelX(Float32List g, int w, int h) {
    final gx = Float32List(w * h);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        gx[i] = (g[i - w + 1] + 2 * g[i + 1] + g[i + w + 1]) -
            (g[i - w - 1] + 2 * g[i - 1] + g[i + w - 1]);
      }
    }
    return gx;
  }

  static double _percentile(Float32List v, double p) {
    final n = v.length ~/ 7 + 1;
    final a = Float32List(n);
    for (var i = 0, k = 0; i < v.length && k < n; i += 7, k++) {
      a[k] = v[i].abs();
    }
    a.sort();
    return a[(p * (n - 1)).round()];
  }

  /// Box-averaged [w]×[h] copy of the source rectangle.
  static Float32List _resample(
      GrayImage src, double x0, double y0, double x1, double y1, int w, int h) {
    final out = Float32List(w * h);
    final fx = (x1 - x0) / w, fy = (y1 - y0) / h;
    for (var y = 0; y < h; y++) {
      final sy0 = (y0 + y * fy).floor().clamp(0, src.height - 1);
      final sy1 =
          math.max(sy0 + 1, (y0 + (y + 1) * fy).floor()).clamp(1, src.height);
      for (var x = 0; x < w; x++) {
        final sx0 = (x0 + x * fx).floor().clamp(0, src.width - 1);
        final sx1 =
            math.max(sx0 + 1, (x0 + (x + 1) * fx).floor()).clamp(1, src.width);
        var sum = 0, n = 0;
        for (var yy = sy0; yy < sy1; yy++) {
          final rowStart = yy * src.width;
          for (var xx = sx0; xx < sx1; xx++) {
            sum += src.pixels[rowStart + xx];
            n++;
          }
        }
        out[y * w + x] = sum / n;
      }
    }
    return out;
  }
}

/// Result of [PlateBoundsFinder.findDetailed], normalized to the image.
class PlateBounds {
  /// Creates a result.
  const PlateBounds({
    required this.area,
    required this.serial,
    required this.shapes,
    this.twoRow = false,
    required this.topEdge,
    required this.bottomEdge,
    required this.leftEdge,
    required this.rightEdge,
  });

  /// The plate area (plate plus a small margin).
  final NormalizedRect area;

  /// The digit row it was built around.
  final NormalizedRect serial;

  /// Character-sized shapes considered for the row.
  final List<NormalizedRect> shapes;

  /// An old two-row plate (region row above the number).
  final bool twoRow;

  /// Which sides came from a found edge (the rest from proportions).
  final bool topEdge, bottomEdge, leftEdge, rightEdge;

  /// The plate's own top and bottom edges were found: a plate, not text
  /// on a page or a screen (which never has both, measured on logged
  /// patrol photos and rendered screen text).
  bool get isPlate => topEdge && bottomEdge;
}

class _Box {
  _Box(this.left, this.top, this.right, this.bottom, this.area);

  final int left, top, right, bottom, area;

  int get width => right - left;
  int get height => bottom - top;
  double get centerX => (left + right) / 2;
}

/// The serial row: extent, median height, tilt.
class _Row {
  _Row(List<_Box> m)
      : left = m.first.left.toDouble(),
        right = m.last.right.toDouble() {
    // Tilt: median of pairwise slopes of the bottoms, then of the tops
    // (robust to a screw on one digit).
    double medianSlope(int Function(_Box) y) {
      final s = <double>[
        for (var i = 0; i < m.length; i++)
          for (var j = i + 1; j < m.length; j++)
            if (m[j].centerX != m[i].centerX)
              (y(m[j]) - y(m[i])) / (m[j].centerX - m[i].centerX)
      ]..sort();
      return s.isEmpty ? 0 : s[s.length ~/ 2];
    }

    slope = ((medianSlope((b) => b.bottom) + medianSlope((b) => b.top)) / 2)
        .clamp(-0.2, 0.2);
    _cx = (left + right) / 2;
    double median(Iterable<double> v) {
      final l = v.toList()..sort();
      return l[l.length ~/ 2];
    }

    _top = median(m.map((b) => b.top - (b.centerX - _cx) * slope));
    height = median(m.map((b) => b.bottom - (b.centerX - _cx) * slope)) - _top;
    final gaps = [
      for (var k = 1; k < m.length; k++) m[k].centerX - m[k - 1].centerX
    ]..sort();
    pitch = gaps[gaps.length ~/ 2];
  }

  /// Extent (extended past missed digits by [PlateBoundsFinder._extend]).
  double left, right;
  late final double height, slope, pitch;
  late final double _cx, _top;

  double get top => _top;
  double get bottom => _top + height;

  double yTop(num x) => _top + (x - _cx) * slope;
  double yBottom(num x) => yTop(x) + height;
}
