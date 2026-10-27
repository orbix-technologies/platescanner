import 'dart:math' as math;
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
    this.leftWord = const [],
    this.latinSideBySide = false,
    this.twoRow = false,
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

  /// Section 1 on plates without a circle: the shapes of the Ge'ez word
  /// left of section 2 / the number (ፖሊስ, ተላላፊ, የተመ, አሕ), left to right.
  final List<NormalizedRect> leftWord;

  /// Section 4 is two letters side by side (AU) rather than stacked.
  final bool latinSideBySide;

  /// Old two-row plate: circle, Ge'ez and Latin region (letters side by
  /// side) on the top row, the number alone below. [geezStack] and
  /// [latinStack] then hold their letters left to right.
  final bool twoRow;

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
  bool _hint = false;

  /// Letters a top-row shape spans: neighbouring letters seen small or at
  /// an angle touch and form one wide shape.
  static int _letters(Blob b) =>
      math.max(1, (b.width / (b.height * 0.9)).round());

  /// Segments [g], a crop of the confirmed plate area.
  ///
  /// When too few characters are found, a two-row plate's big digits may
  /// have been cut by the border clean-up: retried keeping broken rows, and
  /// kept only if it finds a two-row plate with a full number.
  ///
  /// [twoRowHint]: the plate outline search already saw a row of letters
  /// above the number (`PlateBounds.twoRow`), so less is asked of the top
  /// row here.
  PlateSegmentation segment(GrayImage g, {bool twoRowHint = false}) {
    _hint = twoRowHint;
    final first = _segment(g);
    if (first.found && first.numberChars.length >= 5) return first;
    final rows = _segment(g, runLines: true);
    if (rows.twoRow && rows.numberChars.length >= 5) return rows;
    return first;
  }

  PlateSegmentation _segment(GrayImage g, {bool runLines = false}) {
    final w = g.width, h = g.height;
    _notes = [];
    final ink = _inkMask(g);
    var inkCount = 0;
    for (final v in ink) {
      inkCount += v;
    }
    _notes.add('image=${w}x$h ink=${(100 * inkCount / ink.length).round()}%');
    _eraseLines(ink, w, h, runs: runLines);
    // Shapes far wider than any character are characters joined by thin
    // strokes (watermark text, a mouse cursor): thin strokes are removed
    // there only, so thin rings and Ge'ez strokes elsewhere stay intact.
    for (final b in _blobs(ink, w, h)) {
      // Digits joined together are tall and solid; a border line or corner
      // (with letters inside its box) is flat or hollow, and those letters'
      // thin strokes must survive.
      final fill = b.area / (b.width * b.height);
      if (b.width > h * 1.2 && b.height > h * 0.4 && fill >= 0.2) {
        _open(ink, w, h, b);
      }
    }
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
      // Flat remnants of the border line.
      if (b.width > b.height * 4 && b.height < hd * 0.35) return false;
      return b.width >= hd * 0.08;
    }).toList();

    final rows = _twoRows(kept, hd, h);
    if (rows != null) {
      final two = _segmentTwoRow(rows.top, rows.bottom, ink, w, h, hd);
      if (two != null) return two;
    }

    final blobs = _splitTouching(kept, ink, w, hd);
    final columns = _mergeHalves(_columns(blobs, hd), hd);
    var number = _numberRun(columns, hd);
    if (number == null) return _empty(blobs, columns);
    number = _splitJoinedStack(number, columns, ink, w, hd);
    number = _reclaimGappedDigit(number, columns, hd);

    NormalizedRect n(Blob b) =>
        NormalizedRect(b.left / w, b.top / h, b.right / w, b.bottom / h);

    final first = columns.indexOf(number.first);
    final last = columns.indexOf(number.last);
    final numberBox = number.map((c) => c.box).reduce((a, b) => a.union(b));
    final pitch = numberBox.width / number.length;

    // Section 4: the first stack right of the number, within reach — or,
    // with no stack (AU plates), two letter-sized shapes side by side.
    Column? latin;
    final beside = <Column>[];
    for (final c in columns.skip(last + 1)) {
      if (c.box.left - numberBox.right > pitch * 2) break;
      if (c.kind == ColumnKind.stack) {
        latin = c;
        break;
      }
      if (c.box.height >= hd * 0.3 && c.box.height <= hd * 0.85) beside.add(c);
    }
    if (latin == null && beside.length >= 2) {
      final pair = beside.take(2).toList();
      latin = Column(
        [for (final c in pair) c.box],
        pair[0].box.union(pair[1].box),
        ColumnKind.short,
      );
    }

    // Left of the number, right to left: the Ge'ez stack, then the circle.
    Column? geez;
    Column? circle;
    final leftTall = <Column>[];
    final hasCircle =
        columns.take(first).any((c) => c.kind == ColumnKind.circle);
    for (final c in columns.take(first).toList().reversed) {
      if (c.kind == ColumnKind.stack && geez == null && circle == null) {
        // Without a circle, a loose short "stack" is a letter of the word
        // with a mark above it (UN: ተ under the chip), not section 2.
        if (!hasCircle && !c.strictStack && c.box.height < hd * 0.85) continue;
        geez = c;
      } else if (c.kind == ColumnKind.circle && circle == null) {
        circle = c;
      } else if (c.kind == ColumnKind.tall && geez != null) {
        leftTall.insert(0, c);
      }
    }

    // No circle: the Ge'ez word in its place, right to left from section 2
    // (or the number), letter-sized shapes reaching below the chip.
    final word = <Column>[];
    if (circle == null) {
      final anchor = geez ?? number.first;
      var edge = anchor.box.left.toDouble();
      for (final c in columns.take(columns.indexOf(anchor)).toList().reversed) {
        if (edge - c.box.right > pitch * 1.5) break;
        if (c.kind == ColumnKind.tall || c.kind == ColumnKind.circle) break;
        if (c.box.height < hd * 0.15 || c.box.height > hd * 0.9) continue;
        if (c.box.bottom < numberBox.top + hd * 0.5) continue;
        word.insert(0, c);
        edge = c.box.left.toDouble();
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
      leftWord: [for (final c in word) n(c.box)],
      latinSideBySide: latin != null && latin.kind == ColumnKind.short,
      columns: columns,
      notes: _notes,
    );
  }

  /// Old two-row plates: the digits in the lower part of the crop, and four
  /// or more letter-sized shapes on one row entirely above them, spread
  /// across a good part of it (circle, Ge'ez and Latin region). Stacked
  /// region letters of a one-row plate sit inside the band; screws and the
  /// chip above it are smaller; another plate above has digit-high shapes.
  /// Notes why the plate isn't read as two rows.
  Null _no(String why) {
    _notes.add('one row: $why');
    return null;
  }

  ({List<Blob> top, List<Blob> bottom})? _twoRows(
      List<Blob> kept, double hd, int h) {
    final digits =
        kept.where((b) => (b.height - hd).abs() <= hd * 0.2).toList();
    if (digits.length < 4) return _no('digits ${digits.length}');
    // The digits' tilt (median of pairwise slopes of their tops), so a
    // tilted plate's rows are compared along it.
    double cx(Blob b) => (b.left + b.right) / 2;
    final slopes = <double>[
      for (var i = 0; i < digits.length; i++)
        for (var j = i + 1; j < digits.length; j++)
          if (cx(digits[j]) != cx(digits[i]))
            (digits[j].top - digits[i].top) / (cx(digits[j]) - cx(digits[i]))
    ]..sort();
    final slope =
        slopes.isEmpty ? 0.0 : slopes[slopes.length ~/ 2].clamp(-0.25, 0.25);
    final x0 = digits.map(cx).reduce((a, b) => a + b) / digits.length;
    double level(Blob b, num y) => y - slope * (cx(b) - x0);
    final tops = [for (final d in digits) level(d, d.top)]..sort();
    final bandTop = tops[tops.length ~/ 2];
    // The number fills the lower half; a one-row plate's starts near the
    // top of its crop.
    if (bandTop < h * 0.35) {
      return _no('number high (${(bandTop / h).toStringAsFixed(2)})');
    }
    // Digit-high shapes above the band are another plate in view.
    if (digits.any((d) => level(d, d.bottom) <= bandTop)) {
      return _no('digit-high shape above');
    }
    final left = digits.map((d) => d.left).reduce((a, b) => a < b ? a : b);
    final right = digits.map((d) => d.right).reduce((a, b) => a > b ? a : b);
    final candidates = kept
        .where((b) =>
            level(b, b.bottom) <= bandTop - hd * 0.03 &&
            b.height >= hd * 0.2 &&
            b.height <= hd * 0.9)
        .toList();
    if (candidates.length < (_hint ? 2 : 3)) {
      return _no('above ${candidates.length}');
    }
    // One row: centres level with each other.
    double centre(Blob b) => level(b, (b.top + b.bottom) / 2);
    final centres = [for (final b in candidates) centre(b)]..sort();
    final mid = centres[centres.length ~/ 2];
    final hs = [for (final b in candidates) b.height]..sort();
    final ht = hs[hs.length ~/ 2];
    final top = [
      for (final b in candidates)
        if ((centre(b) - mid).abs() <= ht * 0.5) b,
    ];
    // Circle and four letters, about half a digit high; screws and the
    // chip above a one-row plate's digits are smaller and fewer.
    final letters = top
        .where((b) => b.height >= hd * 0.35)
        .map(_letters)
        .fold(0, (a, b) => a + b);
    if (letters < (_hint ? 3 : 4)) {
      return _no('letters $letters of ${top.length}');
    }
    final span = top.map((b) => b.right).reduce((a, b) => a > b ? a : b) -
        top.map((b) => b.left).reduce((a, b) => a < b ? a : b);
    if (span < (right - left) * 0.4) return _no('top row narrow');
    return (
      top: top,
      bottom: [
        for (final b in kept)
          if (!top.contains(b)) b
      ],
    );
  }

  /// Sections of an old two-row plate: the number from the bottom row; on
  /// the top row, left to right, the circle, two Ge'ez letters, the chip
  /// (smaller, skipped) and two Latin letters. Null when the top row
  /// doesn't read so.
  PlateSegmentation? _segmentTwoRow(List<Blob> top, List<Blob> bottom,
      Uint8List ink, int w, int h, double hd) {
    final blobs = _splitTouching(bottom, ink, w, hd);
    final columns = _mergeHalves(_columns(blobs, hd), hd);
    var number = _numberRun(columns, hd);
    if (number == null) return null;
    // A screw merged with the border corner can sit at either end: far
    // wider than the digits.
    final widths = [for (final c in number) c.box.width]..sort();
    final typical = widths[widths.length ~/ 2];
    number = [...number];
    while (number.length > 4 && number.first.box.width > typical * 1.6) {
      number.removeAt(0);
    }
    while (number.length > 4 && number.last.box.width > typical * 1.6) {
      number.removeLast();
    }

    // Top row: its own scale (letters ~ half a digit).
    final heights = [for (final b in top) b.height]..sort();
    final ht = heights[heights.length ~/ 2].toDouble();
    final row = _columns(top, ht * 1.3);
    final circleAt = row.indexWhere((c) => c.kind == ColumnKind.circle);
    // Letter-shaped only: not the chip (smaller), a screw merged with the
    // border corner (wider than tall) or a sliver of the border.
    final letters = [
      for (var i = 0; i < row.length; i++)
        if (i != circleAt &&
            row[i].box.height >= ht * 0.7 &&
            row[i].box.width <= row[i].box.height * 1.3 &&
            row[i].box.width >= ht * 0.25)
          row[i],
    ];
    // A blurred ring isn't recognised: the circle is the first shape.
    var circle = circleAt < 0 ? null : row[circleAt];
    if (circle == null && letters.length >= 5) circle = letters.removeAt(0);
    final full = letters.length >= 4;
    var geez = [
      for (final c in full ? letters.take(2) : const <Column>[]) c.box
    ];
    var latin = [
      for (final c
          in full ? letters.skip(letters.length - 2) : const <Column>[])
        c.box
    ];

    NormalizedRect n(Blob b) =>
        NormalizedRect(b.left / w, b.top / h, b.right / w, b.bottom / h);
    final numberBox = number.map((c) => c.box).reduce((a, b) => a.union(b));
    var code = circle?.box;
    if (!full) {
      // Letters joined into fewer shapes: the top row's layout is fixed
      // (circle, the Ge'ez pair, the chip, the Latin pair; measured
      // against the number's width), so each section is the ink there.
      final x0 = numberBox.left, nw = numberBox.width;
      Blob? zone(double a, double b, {bool letters = true}) {
        final l = x0 + a * nw, r = x0 + b * nw;
        Blob? u;
        for (final t in top) {
          // Not the chip between the pairs (smaller than the letters).
          if (t.right <= l || t.left >= r) continue;
          if (letters && t.height < ht * 0.7) continue;
          final c = Blob(math.max(t.left, l.round()), t.top,
              math.min(t.right, r.round()), t.bottom, 0);
          u = u == null ? c : u.union(c);
        }
        return u;
      }

      List<Blob> pair(Blob? z) => z == null || z.width < 2
          ? const []
          : [
              Blob(z.left, z.top, z.left + z.width ~/ 2, z.bottom, 0),
              Blob(z.left + z.width ~/ 2, z.top, z.right, z.bottom, 0),
            ];
      code ??= zone(-0.08, 0.21, letters: false);
      geez = pair(zone(0.21, 0.52));
      latin = pair(zone(0.62, 1.05));
      if (geez.isNotEmpty || latin.isNotEmpty) _notes.add('top row by layout');
    }
    _notes.add('two rows');
    return PlateSegmentation(
      number: n(numberBox),
      numberChars: [for (final c in number) n(c.box)],
      code: code == null ? null : n(code),
      codeInner: circle == null ? null : _inner(circle).let(n),
      geezStack: [for (final c in geez) n(c)],
      latinStack: [for (final c in latin) n(c)],
      leftDigits: const [],
      latinSideBySide: latin.isNotEmpty,
      twoRow: true,
      columns: [...row, ...columns],
      notes: _notes,
    );
  }

  /// A stencil "1" broken by its gap is classed a stack; with a digit-high
  /// shape a pitch before it and the Ge'ez stack before that, both are
  /// digits the number lost (police plates: "0" and "1" of 012345). On a
  /// 1–5 plate the circle precedes the Ge'ez; on a diplomatic plate the
  /// embassy digits do, and its Ge'ez sits further from the number.
  List<Column> _reclaimGappedDigit(
      List<Column> number, List<Column> columns, double hd) {
    if (number.length < 2) return number;
    final pitch =
        (number.last.box.right - number.first.box.left) / number.length;
    double cx(Column c) => (c.box.left + c.box.right) / 2;
    var i = columns.indexOf(number.first) - 1;
    final pieces = <Column>[];
    // The 1's foot, cut off below.
    while (i >= 0 &&
        columns[i].kind == ColumnKind.short &&
        columns[i].box.height < hd * 0.3) {
      pieces.add(columns[i]);
      i--;
    }
    if (i < 2) return number;
    final gapped = columns[i], digit = columns[i - 1];
    var j = i - 2;
    while (j >= 0 && columns[j].kind == ColumnKind.short) {
      j--;
    }
    if (j < 0 || columns[j].kind != ColumnKind.stack) return number;
    if (gapped.kind != ColumnKind.stack || digit.kind != ColumnKind.tall) {
      return number;
    }
    if (gapped.box.height < hd * 0.85 || gapped.box.width > pitch * 0.6) {
      return number;
    }
    if ((digit.box.height - hd).abs() > hd * 0.15) return number;
    if (cx(number.first) - cx(gapped) > pitch * 1.3 ||
        cx(gapped) - cx(digit) > pitch * 1.0) {
      return number;
    }
    final blobs = [...gapped.blobs, for (final c in pieces) ...c.blobs];
    _notes.add('reclaimed gapped digit');
    return [
      digit,
      Column(blobs, blobs.reduce((a, b) => a.union(b)), ColumnKind.tall),
      ...number,
    ];
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

  /// Morphological opening (3x3 erosion, then dilation) inside [area]:
  /// erases strokes 1-2 px thin — watermark text and a mouse cursor's
  /// outline that join digits into one shape.
  void _open(Uint8List ink, int w, int h, Blob area) {
    final x0 = area.left, x1 = area.right, y0 = area.top, y1 = area.bottom;
    final eroded = Uint8List(w * h);
    for (var y = (y0 > 1 ? y0 : 1); y < (y1 < h - 1 ? y1 : h - 1); y++) {
      for (var x = (x0 > 1 ? x0 : 1); x < (x1 < w - 1 ? x1 : w - 1); x++) {
        var all = 1;
        for (var dy = -1; dy <= 1 && all == 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (ink[(y + dy) * w + x + dx] == 0) {
              all = 0;
              break;
            }
          }
        }
        eroded[y * w + x] = all;
      }
    }
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        var any = 0;
        for (var dy = -1; dy <= 1 && any == 0; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx >= 0 && xx < w && eroded[yy * w + xx] == 1) {
              any = 1;
              break;
            }
          }
        }
        ink[y * w + x] = any;
      }
    }
  }

  /// Clears rows / columns that are mostly ink: the plate border.
  /// Clears the plate border: rows / columns that are mostly ink. With
  /// [runs], only those holding one long unbroken run — a row through the
  /// big digits of a two-row plate (filling most of its width, but broken
  /// by the gaps between them) then stays.
  void _eraseLines(Uint8List ink, int w, int h, {bool runs = false}) {
    int count(int n, int Function(int) at) {
      if (!runs) {
        var c = 0;
        for (var i = 0; i < n; i++) {
          c += at(i);
        }
        return c;
      }
      // Longest run; gaps of a couple of pixels (wear, JPEG) don't end it.
      var best = 0, run = 0, gap = 0;
      for (var i = 0; i < n; i++) {
        if (at(i) == 1) {
          run += gap + 1;
          gap = 0;
          if (run > best) best = run;
        } else if (run > 0 && ++gap > 2) {
          run = 0;
          gap = 0;
        }
      }
      return best;
    }

    for (var y = 0; y < h; y++) {
      if (count(w, (x) => ink[y * w + x]) > w * 0.5) {
        ink.fillRange(y * w, (y + 1) * w, 0);
      }
    }
    for (var x = 0; x < w; x++) {
      if (count(h, (y) => ink[y * w + x]) > h * 0.6) {
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
      // Two stacked letters touching (A over A): a tall, narrow shape whose
      // ink pinches to almost nothing at a row near its middle. Digits (8,
      // 3, 0) keep ink across every row.
      if (tall && b.width <= dw * 0.9) {
        final rows = List<int>.filled(b.height, 0);
        for (var y = 0; y < b.height; y++) {
          for (var x = b.left; x < b.right; x++) {
            rows[y] += ink[(b.top + y) * w + x];
          }
        }
        final maxRow = rows.reduce((a, c) => a > c ? a : c);
        var neck = -1;
        for (var y = (b.height * 0.35).round();
            y <= (b.height * 0.65).round();
            y++) {
          if (y < 0 || y >= b.height) continue;
          if (neck < 0 || rows[y] < rows[neck]) neck = y;
        }
        if (neck > 0 && rows[neck] <= maxRow * 0.12) {
          out.add(Blob(b.left, b.top, b.right, b.top + neck, b.area ~/ 2));
          out.add(
              Blob(b.left, b.top + neck + 1, b.right, b.bottom, b.area ~/ 2));
          continue;
        }
      }
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
        // A column is shapes stacked vertically: one beside another at the
        // same height (a round 6 next to a narrow stacked A) never joins
        // it — unless one encloses the other (a ring and its digit).
        final beside = groups[i].any((o) {
          if (o.contains(b) || b.contains(o)) return false;
          // Only next to a digit-tall shape: small parts side by side make up
          // one Ge'ez letter.
          if (o.height < hd * 0.7 && b.height < hd * 0.7) return false;
          final v = (o.bottom < b.bottom ? o.bottom : b.bottom) -
              (o.top > b.top ? o.top : b.top);
          final shorter = o.height < b.height ? o.height : b.height;
          return v > shorter * 0.3;
        });
        if (overlap > narrow * 0.4 && !beside) {
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

    // Slivers (a stencil cut splitting a "0") join the single-shape digit
    // column right next to them — never a group such as a letter stack (a
    // border line beside it). Narrow digits ("1" stems, ~0.15 of the digit
    // height) are not slivers.
    bool digitShape(int j) =>
        groups[j].length == 1 && boxes[j].height >= hd * 0.7;
    for (var i = 0; i < groups.length; i++) {
      if (boxes[i].width >= hd * 0.1) continue;
      int? j;
      if (i + 1 < groups.length &&
          digitShape(i + 1) &&
          boxes[i + 1].left - boxes[i].right <= hd * 0.15) {
        j = i + 1;
      } else if (i > 0 &&
          digitShape(i - 1) &&
          boxes[i].left - boxes[i - 1].right <= hd * 0.15) {
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
    // Top and bottom halves as groups: a letter broken into pieces (by a
    // watermark stroke) still counts as one letter.
    final box = g.reduce((a, b) => a.union(b));
    // Too narrow for letters: the stem of a stencil "1" broken in two.
    if (box.width < hd * 0.18) return false;
    final mid = box.centerY;
    final upper = g.where((b) => b.centerY < mid).toList();
    final lower = g.where((b) => b.centerY >= mid).toList();
    if (upper.isEmpty || lower.isEmpty) return false;
    final top = upper.reduce((a, b) => a.union(b));
    final bottom = lower.reduce((a, b) => a.union(b));
    if (top.height < hd * 0.25 || bottom.height < hd * 0.25) return false;
    if (bottom.top < top.bottom - top.height * 0.2) return false;
    final ratio = top.height > bottom.height
        ? top.height / bottom.height
        : bottom.height / top.height;
    return ratio <= 2.2;
  }

  ColumnKind _classify(List<Blob> g, Blob box, double hd) {
    final main = g.reduce((a, b) => a.area > b.area ? a : b);
    // Ring with a shape inside (the code digit, centred): the circled code.
    // Down to half as wide as tall, as on a plate seen at 45°.
    final ratio = main.width / main.height;
    if (main.height >= hd * 0.5 &&
        ratio > 0.5 &&
        ratio < 1.35 &&
        g.any((o) =>
            !identical(o, main) &&
            main.contains(o) &&
            o.height >= main.height * 0.25 &&
            (o.centerY - main.centerY).abs() <= main.height * 0.2)) {
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

  /// Two stacked letters joined into one shape (blur, a border or screw
  /// between them) look like one more digit at the number's end — but
  /// taller: digits share one height. Such a last column is split at its
  /// narrowest row in the middle third and becomes the region stack.
  List<Column> _splitJoinedStack(
    List<Column> number,
    List<Column> columns,
    Uint8List ink,
    int w,
    double hd,
  ) {
    if (number.length < 4) return number;
    final heights = number
        .take(number.length - 1)
        .map((c) => c.box.height)
        .toList()
      ..sort();
    final typical = heights[heights.length ~/ 2];
    final last = number.last;
    final i = columns.indexOf(last);
    final stackFollows = i + 1 < columns.length &&
        columns[i + 1].kind == ColumnKind.stack &&
        columns[i + 1].box.left - last.box.right <= hd * 0.6;
    if (stackFollows || last.box.height <= typical * 1.12) return number;

    final b = last.box;
    final rows = List<int>.filled(b.height, 0);
    for (var y = 0; y < b.height; y++) {
      for (var x = b.left; x < b.right; x++) {
        rows[y] += ink[(b.top + y) * w + x];
      }
    }
    var neck = -1;
    for (var y = (b.height / 3).round(); y <= (b.height * 2 / 3).round(); y++) {
      if (y <= 0 || y >= b.height) continue;
      if (neck < 0 || rows[y] < rows[neck]) neck = y;
    }
    if (neck <= 0) return number;
    final top = Blob(b.left, b.top, b.right, b.top + neck, b.area ~/ 2);
    final bottom =
        Blob(b.left, b.top + neck + 1, b.right, b.bottom, b.area ~/ 2);
    columns[i] = Column([top, bottom], b, ColumnKind.stack, strictStack: true);
    return number.sublist(0, number.length - 1);
  }

  /// A tall column and a neighbour with almost no gap between them that
  /// together are no wider than one digit are one digit: a stencil cut
  /// splitting a "0", or a "1" whose flag and foot are separate pieces.
  /// Strict stacks (two letters) never merge.
  List<Column> _mergeHalves(List<Column> columns, double hd) {
    final widths = columns
        .where((c) => c.kind == ColumnKind.tall && c.box.width >= hd * 0.3)
        .map((c) => c.box.width)
        .toList()
      ..sort();
    if (widths.isEmpty) return columns;
    final dw = widths[widths.length ~/ 2].toDouble();
    // A section stack never sits between two digits: one with tall columns
    // close on both sides is the flag and foot of a stencil "1".
    final sandwiched = <Column>{};
    for (var i = 1; i < columns.length - 1; i++) {
      final l = columns[i - 1], c = columns[i], r = columns[i + 1];
      if (c.kind == ColumnKind.stack &&
          l.kind == ColumnKind.tall &&
          r.kind == ColumnKind.tall &&
          c.box.left - l.box.right <= hd * 0.2 &&
          r.box.left - c.box.right <= hd * 0.2) {
        sandwiched.add(c);
      }
    }
    bool piece(Column c) =>
        c.kind == ColumnKind.tall ||
        c.kind == ColumnKind.short ||
        (c.kind == ColumnKind.stack &&
            (!c.strictStack || sandwiched.contains(c)));
    final out = <Column>[];
    for (final c in columns) {
      final prev = out.isEmpty ? null : out.last;
      if (prev != null &&
          (prev.kind == ColumnKind.tall || c.kind == ColumnKind.tall) &&
          piece(prev) &&
          piece(c) &&
          c.box.left - prev.box.right <= hd * 0.15 &&
          c.box.right - prev.box.left <= dw * 1.1) {
        out[out.length - 1] = Column(
          [...prev.blobs, ...c.blobs],
          prev.box.union(c.box),
          ColumnKind.tall,
        );
      } else {
        out.add(c);
      }
    }
    return out;
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

    // Right edge reached so far, including small pieces skipped inside the
    // number's band (a stencil "1" whose stem barely shows leaves only its
    // flag and foot): they bridge the gap between the digits around them.
    var reach = -1;
    for (var ci = 0; ci < columns.length; ci++) {
      final c = columns[ci];
      // Inside the number, a digit broken in two (stencil gap, watermark)
      // looks like a stack; only a strict stack ends the number. At the
      // number's end it is the region stack (letters cut by a screw head).
      // Next digit, looking past small pieces (a stencil "1" foot).
      var nj = ci + 1;
      while (nj < columns.length && columns[nj].kind == ColumnKind.short) {
        nj++;
      }
      final digitFollows = nj < columns.length &&
          columns[nj].kind == ColumnKind.tall &&
          columns[nj].box.left - c.box.right <= hd * 0.8;
      final brokenDigit = c.kind == ColumnKind.stack &&
          !c.strictStack &&
          c.box.height >= hd * 0.7 &&
          run.isNotEmpty &&
          digitFollows;
      if (c.kind != ColumnKind.tall && !brokenDigit) {
        // A stack or a circle is another section and ends the number; small
        // marks between digits (watermark letters, specks) are skipped —
        // the gap check below still ends the run at a real gap.
        if (c.kind == ColumnKind.stack || c.kind == ColumnKind.circle) {
          close();
        } else if (run.isNotEmpty) {
          final band = run.last.box;
          final inBand = c.box.bottom > band.top && c.box.top < band.bottom;
          if (inBand && c.box.left - reach <= hd * 0.6 && c.box.right > reach) {
            reach = c.box.right;
          }
        }
        continue;
      }
      if (run.isNotEmpty && c.box.left - reach > hd * 0.6) close();
      run.add(c);
      reach = c.box.right;
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
