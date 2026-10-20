import 'dart:math' as math;

import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import 'diplomatic_codes.dart';
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

  /// Latin stacks that mark a special plate instead of a region.
  static const _specials = {'UN', 'AU', 'CD'};

  /// A circle read backed by at least this many crops beats the colour.
  static const _strongVotes = 3;

  /// Arranges [ocr] and returns the sections plus the reading they imply.
  ({PlateArrangement arrangement, PlateCandidate candidate}) arrange(
    AreaOcr ocr,
  ) {
    final national = nationalFromOcr(ocr);
    if (national != null) return national;
    var chars = _chars(ocr);
    final ignored = <PlateChar>[];

    // Section 4 from the stacked-letter pass: the first column whose letters
    // name a region. Its column is taken out before the number is found:
    // OCR often merges the two letters into one tall "digit" glued to it.
    // A column cut from the number's last "digit" is only trusted when that
    // character is no real digit (`|`, `!`) or the run was too long for a
    // number — otherwise it would steal a real digit.
    final raw = _number(chars);
    RegionColumn? column;
    for (final c in ocr.regionColumns) {
      final special = _specials.contains(c.letters);
      if (c.letters.length != 2 ||
          (parser.readRegion(c.letters) == null && !special)) {
        continue;
      }
      // UN / AU / CD are distinctive enough to trust even from the last
      // "digit" (diplomatic numbers are only four digits long).
      if (c.source == 'lastDigit' && raw != null && !special) {
        final covered = raw.chars.where(
            (x) => x.box.centerX >= c.box.left && x.box.centerX <= c.box.right);
        final stealsDigit = covered.isNotEmpty &&
            covered.every((x) => _isDigit(x.text)) &&
            raw.runLength <= 7;
        if (stealsDigit) continue;
      }
      column = c;
      break;
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
    // Diplomatic plates carry a four-digit number; others five to seven.
    final number = _number(chars) ??
        (column?.letters == 'CD' ||
                ocr.elements.any((e) => e.text.contains('CD'))
            ? _number(chars, minLength: 4)
            : null);

    if (number == null) {
      final latinSection = useColumn
          ? _columnSection(column)
          : const PlateSection(
              kind: PlateSectionKind.latinRegion,
              value: '',
              detected: false,
            );
      final arrangement = PlateArrangement(
        code: _codeSection(const [], ocr.codeHint, null),
        geezRegion:
            geezFromLatin(_geezSection(const [], null), latinSection.value),
        number: const PlateSection(
          kind: PlateSectionKind.number,
          value: '',
          detected: false,
        ),
        latinRegion: latinSection,
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

    // Special plates: UN / AU / CD in the Latin stack, or a yellow plate
    // (police). Diplomatic plates show the embassy number in big digits at
    // the left.
    String? special = _specials.contains(latin.value) ? latin.value : null;
    final paper = ocr.paperColor;
    if (special == null &&
        paper != null &&
        paper.length == 3 &&
        PaperColor.isYellow(paper[0], paper[1], paper[2])) {
      special = PlateServiceType.police.code;
    }
    String? embassy;
    if (special == 'CD') {
      final left = chars
          .where((c) =>
              !number.chars.contains(c) &&
              _isDigit(c.text) &&
              c.box.centerX < nBox.left &&
              c.box.height >= glyph * 0.6)
          .toList()
        ..sort((a, b) => a.box.left.compareTo(b.box.left));
      if (left.isNotEmpty && left.length <= 3) {
        embassy = left.map((c) => c.text).join();
      }
    }

    final arrangement = PlateArrangement(
      code: _codeSection(
        codeChars,
        ocr.codeHint,
        codeZone,
        ink: ocr.inkColor,
        votes: ocr.codeVotes,
        special: special,
        embassy: embassy,
      ),
      geezRegion: geezFromLatin(_geezSection(geezChars, geezZone), latin.value),
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
    for (var ei = 0; ei < ocr.elements.length; ei++) {
      final e = ocr.elements[ei];
      if (e.symbols.isNotEmpty) {
        for (final s in e.symbols) {
          final t = _normalize(s.text);
          if (t.trim().isNotEmpty) {
            out.add(_Char(t, s.box, lowercase: _isLower(s.text), element: ei));
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
          element: ei,
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
  _Number? _number(List<_Char> chars, {int minLength = 5}) {
    // Within each OCR element first: another line crossing the number (a
    // watermark, a frame edge) would otherwise interleave with its digits.
    _Number? best;
    final elements = chars.map((c) => c.element).toSet();
    for (final e in elements) {
      final n = _numberIn(
        chars.where((c) => c.element == e).toList(),
        minLength,
      );
      if (n != null && (best == null || n.realDigits > best.realDigits)) {
        best = n;
      }
    }
    return best ?? _numberIn(chars, minLength);
  }

  _Number? _numberIn(List<_Char> chars, int minLength) {
    final digits = chars.where((c) => _isDigit(c.text)).toList();
    if (digits.isEmpty) return null;
    final tallest =
        digits.map((c) => c.box.height).reduce((a, b) => a > b ? a : b);
    bool joinable(_Char c) =>
        c.box.height >= tallest * _numberGlyph &&
        (_isDigit(c.text) || (!c.lowercase && _toDigit.containsKey(c.text)));

    final sorted = [...chars]..sort((a, b) => a.box.left.compareTo(b.box.left));
    // Gaps are compared with character width (same axis): the plate's height
    // and width are normalized separately, so height says nothing about x.
    final widths = sorted.where(joinable).map((c) => c.box.width).toList()
      ..sort();
    final charWidth = widths.isEmpty ? 0.0 : widths[widths.length ~/ 2];
    _Number? best;
    var run = <_Char>[];
    void close() {
      var kept = run;
      // Too long: drop letter-for-digit guesses at the edges (a ring read as
      // "D"), then the edge whose width is furthest from a digit's. Real
      // logs: the ring read as "0" is ~3x a digit wide; stacked letters
      // merged into one glyph are ~half a digit wide.
      while (kept.length > 7 && !_isDigit(kept.first.text)) {
        kept = kept.sublist(1);
      }
      while (kept.length > 7 && !_isDigit(kept.last.text)) {
        kept = kept.sublist(0, kept.length - 1);
      }
      while (kept.length > 7) {
        final widths = kept.map((c) => c.box.width).toList()..sort();
        final median = widths[widths.length ~/ 2];
        double off(_Char c) => (math.log(c.box.width / median)).abs();
        kept = off(kept.first) > off(kept.last) + 0.15
            ? kept.sublist(1)
            : kept.sublist(0, kept.length - 1);
      }
      final real = kept.where((c) => _isDigit(c.text)).length;
      if (kept.length >= minLength && real >= minLength - 1) {
        final n = _Number(List.of(kept), runLength: run.length);
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
          if (gap > charWidth * 1.2 || !sameRow) close();
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

  /// Section 1 from already-read inputs (the image-segmentation path):
  /// same rules as [arrange] uses.
  PlateSection codeSection({
    String? hint,
    int? votes,
    NormalizedRect? box,
    List<int>? ink,
    String? special,
    String? embassy,
  }) =>
      _codeSection(
        const [],
        hint,
        box,
        ink: ink,
        votes: votes,
        special: special,
        embassy: embassy,
      );

  /// Section 1, in order of trust:
  ///
  /// 1. a special plate (UN / AU / CD stack, yellow police plate);
  /// 2. the circled-code pass, when backed by [_strongVotes] crops;
  /// 3. the number's ink colour (1 red, 2 blue, 3 green, 4 black,
  ///    5 orange) — except red ↔ orange, which a camera can't tell apart;
  /// 4. a weak circle read, or a code digit read in the code zone.
  PlateSection _codeSection(
    List<_Char> chars,
    String? hint,
    NormalizedRect? zone, {
    List<int>? ink,
    int? votes,
    String? special,
    String? embassy,
  }) {
    final box = zone != null && zone.width > 0.01 ? zone : _union(chars);
    if (special != null) {
      final type = PlateServiceType.fromCode(special);
      final mission = embassy == null
          ? null
          : diplomaticMissions[int.tryParse(embassy) ?? -1];
      return PlateSection(
        kind: PlateSectionKind.code,
        value: special,
        // Diplomatic: the embassy number is what section 1 shows.
        // Diplomatic: the embassy number; others: their Ge'ez word.
        chars: box == null
            ? const []
            : [
                PlateChar(
                    special == 'CD'
                        ? embassy ?? special
                        : type?.amharicLabel ?? special,
                    box)
              ],
        box: box,
        note: special == 'CD'
            ? (embassy == null
                ? 'diplomatic'
                : 'embassy $embassy${mission == null ? '' : ' · $mission'}')
            : type?.label ?? 'special plate',
      );
    }

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
    final strong = value != null && (votes ?? 0) >= _strongVotes;
    if (!strong && ink != null && ink.length == 3) {
      final colour = InkColor.classify(ink[0], ink[1], ink[2]);
      final byColour = PlateServiceType.fromInk(colour)?.code;
      const warm = {'1', '5'}; // red and orange look alike on camera
      final sameFamily = warm.contains(byColour) && warm.contains(value);
      if (byColour != null && byColour != value && !sameFamily) {
        note = value == null ? 'by colour' : 'by colour (circle read $value)';
        value = byColour;
      }
    }
    return PlateSection(
      kind: PlateSectionKind.code,
      value: value ?? '',
      chars: value == null || box == null ? const [] : [PlateChar(value, box)],
      box: box,
      detected: value != null,
      note: note,
    );
  }

  /// The new national plate (`ETH`, 2026) from the whole-area OCR: a line
  /// read as three letters and four digits ([EthiopianPlateParser.
  /// readNationalSerial]). Section 1 is the ኢት / ETH block (boxed on the
  /// `ETH` element when read); there is no region. Null when no line reads
  /// so.
  ({PlateArrangement arrangement, PlateCandidate candidate})? nationalFromOcr(
      AreaOcr ocr) {
    OcrElement? line;
    String? serial;
    for (final e in ocr.elements) {
      serial = parser.readNationalSerial(e.text);
      if (serial != null) {
        line = e;
        break;
      }
    }
    if (line == null || serial == null) return null;
    final b = line.box, n = serial.length;
    final eth = ocr.elements
        .where((e) => e.text.toUpperCase().contains('ETH'))
        .firstOrNull;
    const type = PlateServiceType.national;
    const none = 'none on ETH plates';
    final arrangement = PlateArrangement(
      code: PlateSection(
        kind: PlateSectionKind.code,
        value: type.code,
        chars:
            eth == null ? const [] : [PlateChar(type.amharicLabel!, eth.box)],
        box: eth?.box,
        note: type.label,
      ),
      geezRegion: const PlateSection(
        kind: PlateSectionKind.geezRegion,
        value: '',
        detected: false,
        note: none,
      ),
      number: PlateSection(
        kind: PlateSectionKind.number,
        value: serial,
        chars: [
          for (var i = 0; i < n; i++)
            PlateChar(
              serial[i],
              NormalizedRect(b.left + b.width * i / n, b.top,
                  b.left + b.width * (i + 1) / n, b.bottom),
            ),
        ],
        box: b,
      ),
      latinRegion: const PlateSection(
        kind: PlateSectionKind.latinRegion,
        value: '',
        detected: false,
        note: none,
      ),
    );
    return (
      arrangement: arrangement,
      candidate: _candidate(arrangement, ocr, 0)
    );
  }

  /// Section 2 from section 4 when the Ge'ez itself wasn't read: the
  /// region's Ge'ez abbreviation (AA → አአ, OR → ኦሮ), one letter per
  /// stacked box ([boxes], else the halves of the section's box). Unchanged
  /// when it was read or [latin] names no region.
  PlateSection geezFromLatin(
    PlateSection geez,
    String latin, {
    List<NormalizedRect> boxes = const [],
  }) {
    if (geez.detected) return geez;
    final region = parser.readRegion(latin);
    if (region == null) return geez;
    final letters = region.amharicLabel.split('');
    final box = geez.box;
    final slots = boxes.length == letters.length
        ? boxes
        : box == null
            ? const <NormalizedRect>[]
            : [
                for (var i = 0; i < letters.length; i++)
                  NormalizedRect(
                    box.left,
                    box.top + box.height * i / letters.length,
                    box.right,
                    box.top + box.height * (i + 1) / letters.length,
                  ),
              ];
    return PlateSection(
      kind: PlateSectionKind.geezRegion,
      value: region.amharicLabel,
      chars: [
        if (slots.length == letters.length)
          for (var i = 0; i < letters.length; i++)
            PlateChar(letters[i], slots[i]),
      ],
      box: box,
      note: 'from ${region.code}',
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
    var value = letters.map((c) => c.text).join();
    // Loose letters count only if they name a region or are at most two
    // (more is stray text crossing the plate, e.g. a watermark).
    if (parser.readRegion(value) == null && letters.length > 2) {
      letters.clear();
      value = '';
    }
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
  _Char(this.text, this.box, {this.lowercase = false, this.element = -1});

  /// Index of the OCR element this character came from.
  final int element;
  final String text;
  final NormalizedRect box;

  /// Read as a lowercase letter: plate characters are uppercase, so this is
  /// never a digit misread (a ring read as "o").
  final bool lowercase;
}

class _Number {
  _Number(this.chars, {required this.runLength});
  final List<_Char> chars;

  /// Characters in the run before trimming to seven.
  final int runLength;

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
