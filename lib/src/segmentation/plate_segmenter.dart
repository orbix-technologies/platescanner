import 'dart:typed_data';

import '../models/ocr_frame.dart';

/// Grayscale image (luminance 0–255, row-major).
class GrayImage {
  /// Creates an image.
  GrayImage(this.width, this.height, this.pixels)
      : assert(pixels.length == width * height);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Luminance per pixel.
  final Uint8List pixels;
}

/// A connected ink shape.
class Blob {
  /// Creates a shape.
  Blob(this.left, this.top, this.right, this.bottom, this.area);

  /// Inclusive left / top, exclusive right / bottom, in pixels.
  int left, top, right, bottom;

  /// Ink pixels.
  int area;

  /// Width in pixels.
  int get width => right - left;

  /// Height in pixels.
  int get height => bottom - top;

  /// Horizontal centre.
  double get centerX => (left + right) / 2;

  /// Vertical centre.
  double get centerY => (top + bottom) / 2;

  /// Whether [o] lies inside this shape's box.
  bool contains(Blob o) =>
      o.left >= left && o.right <= right && o.top >= top && o.bottom <= bottom;

  /// Box covering both shapes.
  Blob union(Blob o) => Blob(
        left < o.left ? left : o.left,
        top < o.top ? top : o.top,
        right > o.right ? right : o.right,
        bottom > o.bottom ? bottom : o.bottom,
        area + o.area,
      );

  @override
  String toString() => 'Blob($left,$top ${width}x$height)';
}

/// What a column of ink shapes is, from its geometry alone.
enum ColumnKind {
  /// One shape as tall as a digit.
  tall,

  /// Two shapes, one above the other (stacked letters).
  stack,

  /// A ring with a shape inside (the circled code).
  circle,

  /// Shorter than a digit and not a stack (chip, mark, lone letter).
  short,
}

/// Shapes overlapping horizontally, read top to bottom.
class Column {
  /// Creates a column.
  Column(this.blobs, this.box, this.kind, {this.strictStack = false});

  /// A stack of two similar-height letters (not a digit broken in two).
  final bool strictStack;

  /// Shapes, top to bottom.
  final List<Blob> blobs;

  /// Union of [blobs].
  final Blob box;

  /// Geometry class.
  final ColumnKind kind;

  @override
  String toString() => '${kind.name}$box';
}

/// The plate's four sections found from the image, before any OCR.
class PlateSegmentation {
  /// Creates a result. Boxes are normalized to the analysed image.
  const PlateSegmentation({
    required this.number,
    required this.numberChars,
    required this.code,
    this.codeInner,
    required this.geezStack,
    required this.latinStack,
    required this.leftDigits,
    required this.columns,
    this.notes = const [],
  });

  /// How the segmentation went (threshold, counts), for the session log.
  final List<String> notes;

  /// Section 3: the number's box, or null.
  final NormalizedRect? number;

  /// Section 3: each digit's box, left to right.
  final List<NormalizedRect> numberChars;

  /// Section 1: the circle (or the code's box), or null.
  final NormalizedRect? code;

  /// Section 1: the digit inside the circle (what is read), or null.
  final NormalizedRect? codeInner;

  /// Section 2: the stacked Ge'ez letters, top to bottom.
  final List<NormalizedRect> geezStack;

  /// Section 4: the stacked Latin letters, top to bottom.
  final List<NormalizedRect> latinStack;

  /// Big digits left of the Ge'ez (embassy number on diplomatic plates).
  final List<NormalizedRect> leftDigits;

  /// Every column found, left to right (diagnostics).
  final List<Column> columns;

  /// Whether the number was found.
  bool get found => number != null;
}

/// Finds the plate's sections by the shape and arrangement of its ink:
/// digits are single tall shapes side by side; the region letters are two
/// half-height shapes stacked in one column; the code is a ring with a
/// digit inside. A stacked pair can never join the number, whatever OCR
/// would make of it.
class PlateSegmenter {
  /// Creates a segmenter.
  PlateSegmenter();

  List<String> _notes = [];

  /// Segments [g], a crop of the confirmed plate area.
  PlateSegmentation segment(GrayImage g) {
    final w = g.width, h = g.height;
    _notes = [];
    final ink = _inkMask(g);
    var inkCount = 0;
    for (final v in ink) {
      inkCount += v;
    }
    _notes.add('image=${w}x$h ink=${(100 * inkCount / ink.length).round()}%');
    _eraseLines(ink, w, h);
    final raw = _blobs(ink, w, h)
        .where((b) =>
            b.height >= h * 0.08 && // watermark / noise
            b.width < w * 0.5 && // remaining border
            b.height < h * 0.97)
        .toList();

    // Digit height: the tallest height shared by three or more shapes (the
    // number's digits), so a loose area or other plates in view don't matter.
    final heights = raw
        .where((b) => b.height >= h * 0.12 && b.width <= b.height * 1.2)
        .map((b) => b.height)
        .toList()
      ..sort();
    double? found;
    for (final candidate in heights.reversed) {
      final similar =
          heights.where((x) => (x - candidate).abs() <= candidate * 0.15);
      if (similar.length >= 3) {
        found = similar.reduce((a, b) => a + b) / similar.length;
        break;
      }
    }
    _notes.add('shapes=${raw.length}');
    if (found == null) return _empty(raw);
    final hd = found;
    _notes.add('digitHeight=${hd.round()}');

    // Not plate characters: shapes cut by the crop's top / bottom edge (a
    // neighbouring plate), hollow outlines (border fragments on a tilted
    // plate) and hairline slivers of the border.
    final kept = raw.where((b) {
      if (b.top == 0 || b.bottom == h) return false;
      final fill = b.area / (b.width * b.height);
      if ((b.width > hd * 1.3 || b.height > hd * 1.3) && fill < 0.15) {
        return false;
      }
      return b.width >= hd * 0.08;
    }).toList();

    final blobs = _splitTouching(kept, ink, w, hd);
    final columns = _columns(blobs, hd);
    final number = _numberRun(columns, hd);
    if (number == null) return _empty(blobs, columns);

    NormalizedRect n(Blob b) =>
        NormalizedRect(b.left / w, b.top / h, b.right / w, b.bottom / h);

    final first = columns.indexOf(number.first);
    final last = columns.indexOf(number.last);
    final numberBox = number.map((c) => c.box).reduce((a, b) => a.union(b));
    final pitch = numberBox.width / number.length;

    // Section 4: the first stack right of the number, within reach.
    Column? latin;
    for (final c in columns.skip(last + 1)) {
      if (c.box.left - numberBox.right > pitch * 2) break;
      if (c.kind == ColumnKind.stack) {
        latin = c;
        break;
      }
    }

    // Left of the number, right to left: the Ge'ez stack, then the circle.
    Column? geez;
    Column? circle;
    final leftTall = <Column>[];
    for (final c in columns.take(first).toList().reversed) {
      if (c.kind == ColumnKind.stack && geez == null && circle == null) {
        geez = c;
      } else if (c.kind == ColumnKind.circle && circle == null) {
        circle = c;
      } else if (c.kind == ColumnKind.tall && geez != null) {
        leftTall.insert(0, c);
      }
    }

    return PlateSegmentation(
      number: n(numberBox),
      numberChars: [for (final c in number) n(c.box)],
      code: circle == null ? null : n(circle.box),
      codeInner: circle == null ? null : _inner(circle).let(n),
      geezStack: geez == null ? const [] : [for (final b in geez.blobs) n(b)],
      // Two letters: the two largest shapes (a screw head or speck can sit in
      // the same column), top to bottom.
      latinStack: latin == null
          ? const []
          : [
              for (final b
                  in ([...latin.blobs]
                        ..sort((a, b) => b.area.compareTo(a.area)))
                      .take(2)
                      .toList()
                    ..sort((a, b) => a.top.compareTo(b.top)))
                n(b),
            ],
      leftDigits: [for (final c in leftTall) n(c.box)],
      columns: columns,
      notes: _notes,
    );
  }

  /// Union of the shapes inside a circle column's ring.
  Blob? _inner(Column circle) {
    final ring = circle.blobs.reduce((a, b) => a.area > b.area ? a : b);
    Blob? inner;
    for (final b in circle.blobs) {
      if (identical(b, ring) || !ring.contains(b)) continue;
      inner = inner == null ? b : inner.union(b);
    }
    return inner;
  }

  PlateSegmentation _empty(List<Blob> blobs, [List<Column>? columns]) =>
      PlateSegmentation(
        number: null,
        numberChars: const [],
        code: null,
        geezStack: const [],
        latinStack: const [],
        leftDigits: const [],
        columns: columns ?? const [],
        notes: _notes,
      );

  /// Ink = clearly darker than its neighbourhood (Bradley adaptive
  /// threshold over a window half the crop's height, wider than a digit so bold strokes stay solid). A global
  /// threshold fails when dark car paint or a coloured plate surrounds the
  /// characters; a local one does not.
  Uint8List _inkMask(GrayImage g) {
    final w = g.width, h = g.height;
    // Integral image.
    final integral = Int64List((w + 1) * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0;
      for (var x = 0; x < w; x++) {
        row += g.pixels[y * w + x];
        integral[(y + 1) * (w + 1) + x + 1] =
            integral[y * (w + 1) + x + 1] + row;
      }
    }
    final r = (h / 2).round().clamp(4, 200);
    const t = 0.15;
    final mask = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final y0 = (y - r).clamp(0, h - 1), y1 = (y + r).clamp(0, h - 1);
      for (var x = 0; x < w; x++) {
        final x0 = (x - r).clamp(0, w - 1), x1 = (x + r).clamp(0, w - 1);
        final count = (x1 - x0 + 1) * (y1 - y0 + 1);
        final sum = integral[(y1 + 1) * (w + 1) + x1 + 1] -
            integral[y0 * (w + 1) + x1 + 1] -
            integral[(y1 + 1) * (w + 1) + x0] +
            integral[y0 * (w + 1) + x0];
        if (g.pixels[y * w + x] * count < sum * (1 - t)) mask[y * w + x] = 1;
      }
    }
    _notes.add('adaptive r=$r');
    return mask;
  }

  /// Clears rows / columns that are mostly ink: the plate border.
  void _eraseLines(Uint8List ink, int w, int h) {
    for (var y = 0; y < h; y++) {
      var n = 0;
      for (var x = 0; x < w; x++) {
        n += ink[y * w + x];
      }
      if (n > w * 0.5) {
        for (var x = 0; x < w; x++) {
          ink[y * w + x] = 0;
        }
      }
    }
    for (var x = 0; x < w; x++) {
      var n = 0;
      for (var y = 0; y < h; y++) {
        n += ink[y * w + x];
      }
      if (n > h * 0.6) {
        for (var y = 0; y < h; y++) {
          ink[y * w + x] = 0;
        }
      }
    }
  }

  /// 8-connected components.
  List<Blob> _blobs(Uint8List ink, int w, int h) {
    final seen = Uint8List(w * h);
    final stack = <int>[];
    final out = <Blob>[];
    for (var i = 0; i < w * h; i++) {
      if (ink[i] == 0 || seen[i] == 1) continue;
      seen[i] = 1;
      stack.add(i);
      var l = w, t = h, r = 0, b = 0, area = 0;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final x = p % w, y = p ~/ w;
        area++;
        if (x < l) l = x;
        if (x >= r) r = x + 1;
        if (y < t) t = y;
        if (y >= b) b = y + 1;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= w) continue;
            final q = ny * w + nx;
            if (ink[q] == 1 && seen[q] == 0) {
              seen[q] = 1;
              stack.add(q);
            }
          }
        }
      }
      out.add(Blob(l, t, r, b, area));
    }
    return out;
  }

  /// Splits shapes made of several touching digits (blur, low resolution)
  /// at the weakest points of their vertical ink profile.
  List<Blob> _splitTouching(List<Blob> blobs, Uint8List ink, int w, double hd) {
    final digitWidths = blobs
        .where((b) =>
            b.height >= hd * 0.7 &&
            b.height <= hd * 1.3 &&
            b.width >= hd * 0.25 &&
            b.width <= hd * 0.9)
        .map((b) => b.width)
        .toList()
      ..sort();
    if (digitWidths.isEmpty) return blobs;
    final dw = digitWidths[digitWidths.length ~/ 2].toDouble();

    final out = <Blob>[];
    for (final b in blobs) {
      final tall = b.height >= hd * 0.7 && b.height <= hd * 1.3;
      final parts = (b.width / dw).round();
      // A ring (the circled code) is as wide as two digits but hollow and
      // encloses its digit; touching digits are solid and enclose nothing.
      final encloses = blobs.any((o) => !identical(o, b) && b.contains(o));
      final fill = b.area / (b.width * b.height);
      if (!tall || b.width < dw * 1.75 || parts < 2 || encloses || fill < 0.3) {
        out.add(b);
        continue;
      }
      // Ink per column inside the shape.
      final profile = List<int>.filled(b.width, 0);
      for (var x = 0; x < b.width; x++) {
        for (var y = b.top; y < b.bottom; y++) {
          profile[x] += ink[y * w + b.left + x];
        }
      }
      // Cut near each expected boundary, at the column with least ink.
      final cuts = <int>[];
      for (var k = 1; k < parts; k++) {
        final expected = (b.width * k / parts).round();
        final span = (dw * 0.3).round();
        var best = expected;
        for (var x = expected - span; x <= expected + span; x++) {
          if (x > 0 && x < b.width - 1 && profile[x] < profile[best]) best = x;
        }
        cuts.add(best);
      }
      var start = 0;
      for (final c in [...cuts, b.width]) {
        if (c - start >= 2) {
          out.add(Blob(b.left + start, b.top, b.left + c, b.bottom,
              b.area * (c - start) ~/ b.width));
        }
        start = c;
      }
    }
    return out;
  }

  /// Groups shapes that overlap horizontally into columns and classifies
  /// each by geometry, with [hd] the digit height.
  List<Column> _columns(List<Blob> blobs, double hd) {
    final sorted = [...blobs]..sort((a, b) => a.left.compareTo(b.left));
    final groups = <List<Blob>>[];
    final boxes = <Blob>[];
    for (final b in sorted) {
      var placed = false;
      for (var i = groups.length - 1; i >= 0 && i >= groups.length - 3; i--) {
        final c = boxes[i];
        final overlap = (b.right < c.right ? b.right : c.right) -
            (b.left > c.left ? b.left : c.left);
        final narrow = b.width < c.width ? b.width : c.width;
        if (overlap > narrow * 0.4) {
          groups[i].add(b);
          boxes[i] = c.union(b);
          placed = true;
          break;
        }
      }
      if (!placed) {
        groups.add([b]);
        boxes.add(b);
      }
    }

    // Slivers (a stencil cut splitting a "0") join the column right next to
    // them.
    for (var i = 0; i < groups.length; i++) {
      if (boxes[i].width >= hd * 0.15) continue;
      int? j;
      if (i + 1 < groups.length &&
          boxes[i + 1].left - boxes[i].right <= hd * 0.15) {
        j = i + 1;
      } else if (i > 0 && boxes[i].left - boxes[i - 1].right <= hd * 0.15) {
        j = i - 1;
      }
      if (j == null) continue;
      groups[j].addAll(groups[i]);
      boxes[j] = boxes[j].union(boxes[i]);
      groups.removeAt(i);
      boxes.removeAt(i);
      i--;
    }

    final columns = <Column>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i]..sort((a, b) => a.top.compareTo(b.top));
      final box = boxes[i];
      final kind = _classify(g, box, hd);
      columns.add(Column(g, box, kind,
          strictStack: kind == ColumnKind.stack && _isStrictStack(g, hd)));
    }
    return columns;
  }

  /// Two letters of similar height (each a quarter to 0.7 of a digit) —
  /// not a digit broken by a stencil gap or a watermark into a big piece and
  /// a crumb.
  bool _isStrictStack(List<Blob> g, double hd) {
    final parts = g.where((b) => b.height >= hd * 0.25).toList();
    if (parts.length < 2) return false;
    final top = parts.first, bottom = parts.last;
    final ratio = top.height > bottom.height
        ? top.height / bottom.height
        : bottom.height / top.height;
    return ratio <= 2.2;
  }

  ColumnKind _classify(List<Blob> g, Blob box, double hd) {
    final main = g.reduce((a, b) => a.area > b.area ? a : b);
    // Ring with a shape inside: the circled code.
    final ratio = main.width / main.height;
    if (main.height >= hd * 0.5 &&
        ratio > 0.75 &&
        ratio < 1.35 &&
        g.any((o) => !identical(o, main) && main.contains(o))) {
      return ColumnKind.circle;
    }
    // Two shapes one above the other, each well short of a digit.
    final parts = g.where((b) => b.height >= hd * 0.18).toList();
    if (parts.length >= 2 && box.height >= hd * 0.6) {
      final top = parts.first, bottom = parts.last;
      final separated = bottom.top >= top.bottom - top.height * 0.2;
      if (separated && top.height <= hd * 0.7 && bottom.height <= hd * 0.7) {
        return ColumnKind.stack;
      }
    }
    if (main.height >= hd * 0.7 && main.height <= hd * 1.3) {
      return ColumnKind.tall;
    }
    return ColumnKind.short;
  }

  /// Longest run of adjacent tall columns (three or more) with digit-like
  /// spacing.
  List<Column>? _numberRun(List<Column> columns, double hd) {
    List<Column>? best;
    var run = <Column>[];
    void close() {
      if (run.length >= 3 && (best == null || run.length > best!.length)) {
        best = run;
      }
      run = <Column>[];
    }

    for (final c in columns) {
      // Inside the number, a digit broken in two (stencil gap, watermark)
      // looks like a stack; only a strict stack ends the number.
      final brokenDigit = c.kind == ColumnKind.stack &&
          !c.strictStack &&
          c.box.height >= hd * 0.7 &&
          run.isNotEmpty;
      if (c.kind != ColumnKind.tall && !brokenDigit) {
        // A stack or a circle is another section and ends the number; small
        // marks between digits (watermark letters, specks) are skipped —
        // the gap check below still ends the run at a real gap.
        if (c.kind == ColumnKind.stack || c.kind == ColumnKind.circle) close();
        continue;
      }
      if (run.isNotEmpty && c.box.left - run.last.box.right > hd * 0.6) {
        close();
      }
      run.add(c);
    }
    close();
    return best;
  }
}

extension _Let<T> on T? {
  R? let<R>(R Function(T) f) {
    final v = this;
    return v == null ? null : f(v);
  }
}
