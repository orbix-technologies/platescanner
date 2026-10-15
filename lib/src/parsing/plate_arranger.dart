import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import 'ethiopian_plate_parser.dart';
import 'plate_service_type.dart';

/// Steps 4–5: splits the characters read inside a confirmed plate area into
/// the plate's four sections, left to right:
///
/// 1. **code** — the circled number;
/// 2. **Ge'ez region** — letters stacked vertically (`XX` when unreadable);
/// 3. **number** — the serial;
/// 4. **Latin region** — letters stacked vertically (`A` over `M` → `AM`).
///
/// Works per character and anchors on the number: the longest run of
/// number-sized digits side by side. Everything right of it is the Latin
/// region; everything left of it is the code (leftmost) and the Ge'ez region
/// (between code and number). Characters much smaller than the number
/// (ETH marks, the vertical security number) belong to no section.
class PlateArranger {
  /// Creates an arranger.
  const PlateArranger({this.parser = const EthiopianPlateParser()});

  /// Parser used to validate fields.
  final EthiopianPlateParser parser;

  // OCR confusions, per section.
  static const _toDigit = {
    'O': '0', 'Q': '0', 'D': '0', 'U': '0', //
    'I': '1', 'L': '1', 'J': '1', '|': '1',
    'Z': '2', 'S': '5', 'B': '8', 'G': '6',
  };
  static const _toLetter = {
    '0': 'O',
    '1': 'I',
    '2': 'Z',
    '4': 'A',
    '5': 'S',
    '6': 'G',
    '8': 'B',
  };

  /// Number characters are at least this fraction of the tallest digit.
  static const _numberGlyph = 0.75;

  /// Section characters are at least this fraction of the number's height.
  static const _minGlyph = 0.25;

  /// Arranges [ocr] and returns the sections plus the reading they imply.
  ({PlateArrangement arrangement, PlateCandidate candidate}) arrange(
    AreaOcr ocr,
  ) {
    final chars = _chars(ocr);
    final number = _number(chars);
    final ignored = <PlateChar>[];

    if (number == null) {
      final arrangement = PlateArrangement(
        code: _codeSection(const [], ocr.codeHint, null),
        geezRegion: _geezSection(const [], null, null),
        number: const PlateSection(
          kind: PlateSectionKind.number,
          value: '',
          detected: false,
        ),
        latinRegion: const PlateSection(
          kind: PlateSectionKind.latinRegion,
          value: '',
          detected: false,
        ),
        ignored: [for (final c in chars) PlateChar(c.text, c.box)],
      );
      return (
        arrangement: arrangement,
        candidate: _candidate(arrangement, ocr, 0),
      );
    }

    final nBox = number.box;
    final glyph = number.glyph;
    final left = <_Char>[];
    final right = <_Char>[];
    for (final c in chars) {
      if (number.chars.contains(c)) continue;
      if (c.box.height < glyph * _minGlyph) {
        ignored.add(PlateChar(c.text, c.box));
      } else if (c.box.centerX >= nBox.right - glyph * 0.1) {
        right.add(c);
      } else if (c.box.centerX <= nBox.left + glyph * 0.1) {
        left.add(c);
      } else {
        ignored.add(PlateChar(c.text, c.box));
      }
    }

    // Left of the number: code (leftmost group) then Ge'ez. Ge'ez script
    // always belongs to the Ge'ez section, wherever it is.
    final geezScript = left.where((c) => _isGeez(c.text)).toList();
    final clusters = _clusters(
      left.where((c) => !_isGeez(c.text)).toList(),
      gap: glyph * 0.15,
    );
    List<_Char> codeChars = const [];
    final geezChars = <_Char>[...geezScript];
    if (clusters.isNotEmpty) {
      final first = clusters.first;
      // One group only: the circle sits in the outer half of the space
      // left of the number, the Ge'ez next to the number.
      final firstX = _union(first)!.centerX;
      final geezX = geezScript.isEmpty ? null : _union(geezScript)!.left;
      final looksLikeCode = first.any((c) => _codeDigit(c.text) != null) ||
          clusters.length > 1 ||
          (geezX != null && firstX < geezX) ||
          firstX < nBox.left * 0.5;
      if (looksLikeCode) {
        codeChars = first;
        for (final c in clusters.skip(1)) {
          geezChars.addAll(c);
        }
      } else {
        for (final c in clusters) {
          geezChars.addAll(c);
        }
      }
    }

    final arrangement = PlateArrangement(
      code: _codeSection(codeChars, ocr.codeHint, nBox),
      geezRegion: _geezSection(geezChars, codeChars, nBox),
      number: number.section,
      latinRegion: _latinSection(right),
      ignored: ignored,
    );
    return (
      arrangement: arrangement,
      candidate: _candidate(arrangement, ocr, number.corrections),
    );
  }

  /// All characters with boxes; spread evenly when the backend gave none.
  List<_Char> _chars(AreaOcr ocr) {
    final out = <_Char>[];
    for (final e in ocr.elements) {
      if (e.symbols.isNotEmpty) {
        for (final s in e.symbols) {
          final t = _normalize(s.text);
          if (t.trim().isNotEmpty) out.add(_Char(t, s.box));
        }
        continue;
      }
      final text = e.text;
      final step = text.isEmpty ? 0.0 : e.box.width / text.length;
      for (var i = 0; i < text.length; i++) {
        final t = _normalize(text[i]);
        if (t.trim().isEmpty) continue;
        final l = e.box.left + i * step;
        out.add(_Char(t, NormalizedRect(l, e.box.top, l + step, e.box.bottom)));
      }
    }
    return out;
  }

  static String _normalize(String ch) {
    if (ch.isEmpty) return ch;
    final c = ch.codeUnitAt(0);
    // Circled digits ①–⑤.
    if (c >= 0x2460 && c <= 0x2464) return '${c - 0x245F}';
    return ch.toUpperCase();
  }

  static bool _isDigit(String t) =>
      t.length == 1 && t.codeUnitAt(0) >= 0x30 && t.codeUnitAt(0) <= 0x39;

  static bool _isGeez(String t) =>
      t.isNotEmpty && t.codeUnitAt(0) >= 0x1200 && t.codeUnitAt(0) <= 0x137F;

  static bool _isLatin(String t) =>
      t.length == 1 && t.codeUnitAt(0) >= 0x41 && t.codeUnitAt(0) <= 0x5A;

  /// Section 3: the longest run of number-sized, digit-like characters
  /// side by side on one row (5–7 long, mostly real digits).
  _Number? _number(List<_Char> chars) {
    final digits = chars.where((c) => _isDigit(c.text)).toList();
    if (digits.isEmpty) return null;
    final tallest =
        digits.map((c) => c.box.height).reduce((a, b) => a > b ? a : b);
    final big = chars
        .where((c) =>
            c.box.height >= tallest * _numberGlyph &&
            (_isDigit(c.text) || _toDigit.containsKey(c.text)))
        .toList()
      ..sort((a, b) => a.box.left.compareTo(b.box.left));

    _Number? best;
    var run = <_Char>[];
    void close() {
      final real = run.where((c) => _isDigit(c.text)).length;
      if (run.length >= 5 && real >= 4) {
        // Too long: keep the rightmost seven (a stray mark on the left).
        final kept = run.length > 7 ? run.sublist(run.length - 7) : run;
        final n = _Number(List.of(kept));
        if (best == null || n.realDigits > best!.realDigits) best = n;
      }
      run = <_Char>[];
    }

    for (final c in big) {
      if (run.isNotEmpty) {
        final prev = run.last;
        final gap = c.box.left - prev.box.right;
        final sameRow =
            (c.box.centerY - prev.box.centerY).abs() < prev.box.height * 0.4;
        if (gap > tallest * 0.8 || !sameRow) close();
      }
      run.add(c);
    }
    close();
    return best;
  }

  /// Splits characters (sorted by x) where the horizontal gap exceeds [gap].
  List<List<_Char>> _clusters(List<_Char> chars, {required double gap}) {
    final sorted = [...chars]..sort((a, b) => a.box.left.compareTo(b.box.left));
    final out = <List<_Char>>[];
    for (final c in sorted) {
      if (out.isEmpty) {
        out.add([c]);
        continue;
      }
      final right =
          out.last.map((x) => x.box.right).reduce((a, b) => a > b ? a : b);
      if (c.box.left - right > gap) {
        out.add([c]);
      } else {
        out.last.add(c);
      }
    }
    return out;
  }

  String? _codeDigit(String t) {
    final d = _isDigit(t) ? t : _toDigit[t];
    return PlateServiceType.isKnown(d) ? d : null;
  }

  /// Section 1: the circled-code pass wins; else a code digit read in the
  /// leftmost cluster (a ring read as a letter is not a code).
  PlateSection _codeSection(
    List<_Char> chars,
    String? hint,
    NormalizedRect? number,
  ) {
    String? value;
    if (PlateServiceType.isKnown(hint) && int.tryParse(hint!) != null) {
      value = hint;
    } else {
      for (final c in chars) {
        value = _codeDigit(c.text);
        if (value != null) break;
      }
    }
    var box = _union(chars);
    if (box == null && number != null && value != null) {
      // Located by the circle pass only: the area left of the number.
      box = NormalizedRect(
        0,
        number.top,
        (number.left * 0.45).clamp(0.02, 1.0),
        number.bottom,
      );
    }
    return PlateSection(
      kind: PlateSectionKind.code,
      value: value ?? '',
      chars: value == null || box == null ? const [] : [PlateChar(value, box)],
      box: box,
      detected: value != null,
    );
  }

  /// Section 2: Ge'ez characters if the recogniser produced any, else `XX`.
  PlateSection _geezSection(
    List<_Char> chars,
    List<_Char>? code,
    NormalizedRect? number,
  ) {
    final geez = chars.where((c) => _isGeez(c.text)).toList()
      ..sort((a, b) => a.box.top.compareTo(b.box.top));
    var box = _union(chars);
    if (box == null && number != null) {
      // Not read at all: the gap between the code and the number.
      final from = _union(code ?? const [])?.right ?? number.left * 0.45;
      if (number.left - from > 0.02) {
        box = NormalizedRect(from, number.top, number.left, number.bottom);
      }
    }
    if (geez.isEmpty) {
      return PlateSection(
        kind: PlateSectionKind.geezRegion,
        value: PlateSection.geezPlaceholder,
        box: box,
        detected: false,
      );
    }
    return PlateSection(
      kind: PlateSectionKind.geezRegion,
      value: geez.map((c) => c.text).join(),
      chars: [for (final c in geez) PlateChar(c.text, c.box)],
      box: box,
    );
  }

  /// Section 4: Latin letters right of the number, stacked top to bottom.
  PlateSection _latinSection(List<_Char> chars) {
    final letters = <_Char>[];
    for (final c in chars) {
      final t = _isLatin(c.text) ? c.text : _toLetter[c.text];
      if (t != null) letters.add(_Char(t, c.box));
    }
    // Top to bottom; side-by-side letters on one row left to right.
    letters.sort((a, b) {
      final sameRow =
          (a.box.centerY - b.box.centerY).abs() < a.box.height * 0.5;
      return sameRow
          ? a.box.left.compareTo(b.box.left)
          : a.box.top.compareTo(b.box.top);
    });
    final value = letters.map((c) => c.text).join();
    return PlateSection(
      kind: PlateSectionKind.latinRegion,
      value: value,
      chars: [for (final c in letters) PlateChar(c.text, c.box)],
      box: _union(letters),
      detected: value.isNotEmpty,
    );
  }

  PlateCandidate _candidate(PlateArrangement a, AreaOcr ocr, int corrections) {
    final code = a.code.value.isEmpty ? null : a.code.value;
    final serial = a.number.value.isEmpty ? null : a.number.value;
    final region = parser.readRegion(a.latinRegion.value);
    final confidences =
        ocr.elements.map((e) => e.confidence).whereType<double>().toList();
    var confidence = confidences.isEmpty
        ? 0.8
        : confidences.reduce((x, y) => x + y) / confidences.length;
    for (var i = 0; i < corrections; i++) {
      confidence *= 0.95;
    }
    return PlateCandidate(
      code: code,
      regionCode: region?.code,
      serial: serial,
      layout: PlateLayout.singleRow,
      rawText: a.layoutText,
      confidence: confidence.clamp(0.0, 1.0),
      issues: parser.validate(
        code: code,
        regionCode: region?.code,
        serial: serial,
      ),
    );
  }

  static NormalizedRect? _union(List<_Char> chars) {
    NormalizedRect? box;
    for (final c in chars) {
      box = box == null ? c.box : box.union(c.box);
    }
    return box;
  }
}

class _Char {
  _Char(this.text, this.box);
  final String text;
  final NormalizedRect box;
}

class _Number {
  _Number(this.chars);
  final List<_Char> chars;

  int get realDigits =>
      chars.where((c) => PlateArranger._isDigit(c.text)).length;

  int get corrections => chars.length - realDigits;

  double get glyph =>
      chars.map((c) => c.box.height).reduce((a, b) => a > b ? a : b);

  NormalizedRect get box => PlateArranger._union(chars)!;

  static String _digit(String t) =>
      PlateArranger._isDigit(t) ? t : PlateArranger._toDigit[t]!;

  String get value => chars.map((c) => _digit(c.text)).join();

  PlateSection get section => PlateSection(
        kind: PlateSectionKind.number,
        value: value,
        chars: [for (final c in chars) PlateChar(_digit(c.text), c.box)],
        box: box,
      );
}
