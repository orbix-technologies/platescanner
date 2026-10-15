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
    var chars = _chars(ocr);
    final ignored = <PlateChar>[];

    // Section 4 from the stacked-letter pass: the first column whose letters
    // name a region. Its column is taken out before the number is found:
    // OCR often merges the two letters into one tall "digit" glued to it.
    RegionColumn? column;
    for (final c in ocr.regionColumns) {
      if (c.letters.length == 2 && parser.readRegion(c.letters) != null) {
        column = c;
        break;
      }
    }
    final useColumn = column != null;
    if (column != null) {
      final box = column.box;
      final inColumn = chars
          .where((c) => c.box.centerX >= box.left && c.box.centerX <= box.right)
          .toList();
      for (final c in inColumn) {
        ignored.add(PlateChar(c.text, c.box));
      }
      chars = chars.where((c) => !inColumn.contains(c)).toList();
    }
    final number = _number(chars);

    if (number == null) {
      final arrangement = PlateArrangement(
        code: _codeSection(const [], ocr.codeHint, null, null),
        geezRegion: _geezSection(const [], null),
        number: const PlateSection(
          kind: PlateSectionKind.number,
          value: '',
          detected: false,
        ),
        latinRegion: useColumn
            ? _columnSection(column)
            : const PlateSection(
                kind: PlateSectionKind.latinRegion,
                value: '',
                detected: false,
              ),
        ignored: [
          ...ignored,
          for (final c in chars) PlateChar(c.text, c.box),
        ],
      );
      return (
        arrangement: arrangement,
        candidate: _candidate(arrangement, ocr, 0),
      );
    }

    final nBox = number.box;
    final glyph = number.glyph;

    // The other sections sit at fixed distances from the number, measured in
    // digit pitch p (measured on real plates: circle centre ≈ 2.8p left of
    // the number, Ge'ez stack ≈ 1.6p, security chip ≈ 0.6p, Latin stack
    // 0.1–1.0p right). Characters are assigned by the zone they fall in.
    final p = nBox.width / number.chars.length;
    double cx(double v) => v.clamp(0.0, 1.0);
    final codeZone = NormalizedRect(cx(nBox.left - 3.6 * p), nBox.top,
        cx(nBox.left - 2.0 * p), nBox.bottom);
    final geezZone = NormalizedRect(cx(nBox.left - 2.0 * p), nBox.top,
        cx(nBox.left - 1.05 * p), nBox.bottom);
    final latinZone = NormalizedRect(cx(nBox.right + 0.05 * p), nBox.top,
        cx(nBox.right + 1.6 * p), nBox.bottom);
    bool inZone(_Char c, NormalizedRect z) =>
        c.box.centerX >= z.left && c.box.centerX <= z.right;

    final codeChars = <_Char>[];
    final geezChars = <_Char>[];
    final right = <_Char>[];
    for (final c in chars) {
      if (number.chars.contains(c)) continue;
      if (c.box.height < glyph * _minGlyph) {
        ignored.add(PlateChar(c.text, c.box));
      } else if (_isGeez(c.text) && c.box.centerX < nBox.left) {
        geezChars.add(c); // Ge'ez script is section 2 wherever it lands
      } else if (inZone(c, codeZone)) {
        codeChars.add(c);
      } else if (inZone(c, geezZone)) {
        geezChars.add(c);
      } else if (c.box.centerX >= nBox.right - glyph * 0.1 &&
          c.box.centerX <= latinZone.right) {
        right.add(c);
      } else {
        ignored.add(PlateChar(c.text, c.box));
      }
    }

    final latin = useColumn ? _columnSection(column) : _latinSection(right);
    final arrangement = PlateArrangement(
      code: _codeSection(codeChars, ocr.codeHint, codeZone, ocr.inkColor),
      geezRegion: _geezSection(geezChars, geezZone),
      number: number.section,
      // Show where section 4 is expected even when nothing was read there.
      latinRegion: latin.box != null
          ? latin
          : PlateSection(
              kind: latin.kind,
              value: latin.value,
              chars: latin.chars,
              box: latinZone.width > 0.01 ? latinZone : null,
              detected: latin.detected,
            ),
      ignored: [
        ...ignored,
        if (useColumn)
          for (final c in right) PlateChar(c.text, c.box),
      ],
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
          if (t.trim().isNotEmpty) {
            out.add(_Char(t, s.box, lowercase: _isLower(s.text)));
          }
        }
        continue;
      }
      final text = e.text;
      final step = text.isEmpty ? 0.0 : e.box.width / text.length;
      for (var i = 0; i < text.length; i++) {
        final t = _normalize(text[i]);
        if (t.trim().isEmpty) continue;
        final l = e.box.left + i * step;
        out.add(_Char(
          t,
          NormalizedRect(l, e.box.top, l + step, e.box.bottom),
          lowercase: _isLower(text[i]),
        ));
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

  static bool _isLower(String t) =>
      t.length == 1 && t.codeUnitAt(0) >= 0x61 && t.codeUnitAt(0) <= 0x7A;

  static bool _isDigit(String t) =>
      t.length == 1 && t.codeUnitAt(0) >= 0x30 && t.codeUnitAt(0) <= 0x39;

  static bool _isGeez(String t) =>
      t.isNotEmpty && t.codeUnitAt(0) >= 0x1200 && t.codeUnitAt(0) <= 0x137F;

  static bool _isLatin(String t) =>
      t.length == 1 && t.codeUnitAt(0) >= 0x41 && t.codeUnitAt(0) <= 0x5A;

  /// Section 3: the longest run of number-sized, digit-like characters side
  /// by side on one row (5–7 long, mostly real digits). Anything else on the
  /// row between them (a `-`, a symbol) breaks the run.
  _Number? _number(List<_Char> chars) {
    final digits = chars.where((c) => _isDigit(c.text)).toList();
    if (digits.isEmpty) return null;
    final tallest =
        digits.map((c) => c.box.height).reduce((a, b) => a > b ? a : b);
    bool joinable(_Char c) =>
        c.box.height >= tallest * _numberGlyph &&
        (_isDigit(c.text) || (!c.lowercase && _toDigit.containsKey(c.text)));

    final sorted = [...chars]..sort((a, b) => a.box.left.compareTo(b.box.left));
    _Number? best;
    var run = <_Char>[];
    void close() {
      var kept = run;
      // Too long: drop letter-for-digit guesses at the edges (a ring read as
      // "D"), then extra characters on the right (merged stacked letters).
      while (kept.length > 7 && !_isDigit(kept.first.text)) {
        kept = kept.sublist(1);
      }
      while (kept.length > 7 && !_isDigit(kept.last.text)) {
        kept = kept.sublist(0, kept.length - 1);
      }
      if (kept.length > 7) kept = kept.sublist(0, 7);
      final real = kept.where((c) => _isDigit(c.text)).length;
      if (kept.length >= 5 && real >= 4) {
        final n = _Number(List.of(kept));
        if (best == null || n.realDigits > best!.realDigits) best = n;
      }
      run = <_Char>[];
    }

    for (final c in sorted) {
      if (run.isNotEmpty) {
        final prev = run.last;
        final top = run.map((x) => x.box.top).reduce((a, b) => a < b ? a : b);
        final bottom =
            run.map((x) => x.box.bottom).reduce((a, b) => a > b ? a : b);
        final onRow = c.box.centerY > top && c.box.centerY < bottom;
        if (joinable(c)) {
          final gap = c.box.left - prev.box.right;
          final sameRow =
              (c.box.centerY - prev.box.centerY).abs() < prev.box.height * 0.4;
          if (gap > tallest * 0.8 || !sameRow) close();
        } else if (onRow) {
          close();
        }
      }
      if (joinable(c)) run.add(c);
    }
    close();
    return best;
  }

  String? _codeDigit(String t) {
    final d = _isDigit(t) ? t : _toDigit[t];
    return PlateServiceType.isKnown(d) ? d : null;
  }

  /// Section 1: the circled-code pass wins; else a code digit read in the
  /// code zone (a ring read as a letter is not a code). [zone] is where the
  /// circle sits.
  ///
  /// Last resort: the number's ink colour, which encodes the same category
  /// (1 red, 2 blue, 3 green, 4 black, 5 orange).
  PlateSection _codeSection(
    List<_Char> chars,
    String? hint,
    NormalizedRect? zone,
    List<int>? ink,
  ) {
    String? value;
    String? note;
    if (PlateServiceType.isKnown(hint) && int.tryParse(hint!) != null) {
      value = hint;
    } else {
      for (final c in chars) {
        value = _codeDigit(c.text);
        if (value != null) break;
      }
    }
    if (value == null && ink != null && ink.length == 3) {
      final colour = InkColor.classify(ink[0], ink[1], ink[2]);
      value = PlateServiceType.fromInk(colour)?.code;
      if (value != null) note = 'by colour';
    }
    final box = zone != null && zone.width > 0.01 ? zone : _union(chars);
    return PlateSection(
      kind: PlateSectionKind.code,
      value: value ?? '',
      chars: value == null || box == null ? const [] : [PlateChar(value, box)],
      box: box,
      detected: value != null,
      note: note,
    );
  }

  /// Section 2: Ge'ez characters if the recogniser produced any, else `XX`.
  /// [zone] is where the stack sits.
  PlateSection _geezSection(List<_Char> chars, NormalizedRect? zone) {
    final geez = chars.where((c) => _isGeez(c.text)).toList()
      ..sort((a, b) => a.box.top.compareTo(b.box.top));
    final box = zone != null && zone.width > 0.01 ? zone : _union(chars);
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

  /// Section 4 from the stacked-letter pass.
  PlateSection _columnSection(RegionColumn column) => PlateSection(
        kind: PlateSectionKind.latinRegion,
        value: column.letters,
        chars: [
          PlateChar(column.letters[0], column.topHalf),
          PlateChar(column.letters[1], column.bottomHalf),
        ],
        box: column.box,
      );

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
  _Char(this.text, this.box, {this.lowercase = false});
  final String text;
  final NormalizedRect box;

  /// Read as a lowercase letter: plate characters are uppercase, so this is
  /// never a digit misread (a ring read as "o").
  final bool lowercase;
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
