import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../recognition/plate_recognition_service.dart';
import '../segmentation/plate_segmenter.dart';
import 'ethiopian_plate_parser.dart';
import 'plate_arranger.dart';
import 'plate_service_type.dart';

/// One crop to read and what it is for.
class SectionCrop {
  /// Creates a crop request.
  SectionCrop(
    this.role,
    this.index,
    this.box,
    this.inArea, {
    List<NormalizedRect>? group,
    this.repeat = 1,
  }) : group = group ?? [box];

  /// `number`, `digit`, `latin`, `latinWord`, `code`, `codeRepeat` or
  /// `embassy`.
  final String role;

  /// Areas (frame-normalized) read side by side as one word.
  final List<NormalizedRect> group;

  /// Times the areas are drawn side by side.
  final int repeat;

  /// What is sent to the native reader.
  CropSpec get spec => group.length == 1
      ? CropSpec(group.first, repeat: repeat)
      : CropSpec.group(group);

  /// Position within its role (digit / letter order).
  final int index;

  /// Box normalized to the captured frame (what is sent for reading).
  final NormalizedRect box;

  /// Same box normalized to the plate area (what is drawn).
  final NormalizedRect inArea;
}

/// Reads the plate section by section from image segmentation (step 3):
/// each section is cut out by [PlateSegmenter] and read alone, so a
/// vertical stack can never be read into the horizontal number.
class PlateSectionReader {
  /// Creates a reader.
  const PlateSectionReader({this.parser = const EthiopianPlateParser()});

  /// Parser used for validation.
  final EthiopianPlateParser parser;

  static const _specials = {'UN', 'AU', 'CD'};
  static const _toDigit = {
    'O': '0', 'Q': '0', 'D': '0', 'U': '0', 'o': '0', //
    'I': '1', 'L': '1', 'l': '1', '|': '1', 'i': '1', 'J': '1',
    // The plate font's notched 0 is read as G or D (session logs).
    'Z': '2', 'z': '2', 'S': '5', 's': '5', 'B': '8', 'G': '0',
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
  static const _noise = {
    '(', ')', '[', ']', '{', '}', '.', ',', '-', '_', "'", '"', ':', ';', //
    '/', '\\', '|', '!', '^', '%', '@', '°', '*', '~', '`',
  };

  /// The crops to read for [seg], whose boxes are normalized to [area].
  ///
  /// Single digits read poorly alone, so they are only requested with
  /// [digits] — a second round when the whole-number reads disagree.
  List<SectionCrop> cropsFor(
    PlateSegmentation seg,
    NormalizedRect area, {
    bool digits = false,
  }) {
    NormalizedRect frame(NormalizedRect r) => NormalizedRect(
          area.left + r.left * area.width,
          area.top + r.top * area.height,
          area.left + r.right * area.width,
          area.top + r.bottom * area.height,
        );
    NormalizedRect pad(NormalizedRect r, double fx, double fy) {
      final dx = r.width * fx, dy = r.height * fy;
      return NormalizedRect(
        (r.left - dx).clamp(0.0, 1.0),
        (r.top - dy).clamp(0.0, 1.0),
        (r.right + dx).clamp(0.0, 1.0),
        (r.bottom + dy).clamp(0.0, 1.0),
      );
    }

    SectionCrop crop(String role, int i, NormalizedRect r) =>
        SectionCrop(role, i, frame(r), r);

    final out = <SectionCrop>[];
    final number = seg.number;
    if (number != null) {
      // Padded up to a third of a digit sideways, but never past halfway
      // to the neighbouring stack.
      final pitch = number.width / seg.numberChars.length;
      var left = number.left - pitch * 0.3;
      var right = number.right + pitch * 0.3;
      // Two-row plates: the region letters are above the number.
      if (seg.geezStack.isNotEmpty && !seg.twoRow) {
        final g =
            seg.geezStack.map((r) => r.right).reduce((a, b) => a > b ? a : b);
        if (left < (g + number.left) / 2) left = (g + number.left) / 2;
      }
      if (seg.latinStack.isNotEmpty && !seg.twoRow) {
        final l =
            seg.latinStack.map((r) => r.left).reduce((a, b) => a < b ? a : b);
        if (right > (l + number.right) / 2) right = (l + number.right) / 2;
      }
      out.add(crop(
        'number',
        0,
        NormalizedRect(
          left.clamp(0.0, 1.0),
          (number.top - number.height * 0.1).clamp(0.0, 1.0),
          right.clamp(0.0, 1.0),
          (number.bottom + number.height * 0.1).clamp(0.0, 1.0),
        ),
      ));
    }
    if (digits) {
      return [
        for (var i = 0; i < seg.numberChars.length; i++)
          crop('digit', i, pad(seg.numberChars[i], 0.15, 0.08)),
      ];
    }
    final letters = [
      for (var i = 0; i < seg.latinStack.length; i++)
        crop('latin', i, pad(seg.latinStack[i], 0.2, 0.15)),
    ];
    out.addAll(letters);
    if (letters.length == 2) {
      // The stacked letters side by side read as one word ("ET"): OCR reads
      // a word far more reliably than a lone letter.
      out.add(SectionCrop(
        'latinWord',
        0,
        letters.first.box,
        letters.first.inArea,
        group: [for (final l in letters) l.box],
      ));
    }
    final inner = seg.codeInner ?? seg.code;
    if (inner != null) {
      // Tight around the digit so little of the ring shows.
      final c = crop('code', 0, pad(inner, 0.1, 0.08));
      out.add(c);
      // The digit drawn three times reads as a word ("444").
      out.add(SectionCrop('codeRepeat', 0, c.box, c.inArea, repeat: 3));
    }
    for (var i = 0; i < seg.leftDigits.length; i++) {
      out.add(crop('embassy', i, pad(seg.leftDigits[i], 0.15, 0.08)));
    }
    if (seg.leftDigits.length >= 2) {
      // The embassy number as one word ("28"): lone digits often read as
      // nothing (session logs).
      out.add(crop(
        'embassyWord',
        0,
        pad(seg.leftDigits.reduce((a, b) => a.union(b)), 0.1, 0.08),
      ));
    }
    return out;
  }

  /// Builds the four sections from [seg] and the [reads] of [cropsFor]
  /// (one `[colour, bw, clean]` triple per crop). [ocr] adds the colours and
  /// circle pass of the whole-area read.
  ({PlateArrangement arrangement, PlateCandidate candidate}) read(
    PlateSegmentation seg,
    List<SectionCrop> crops,
    List<List<String?>> reads,
    AreaOcr ocr,
  ) {
    List<String?> readsOf(String role, int i) {
      for (var k = 0; k < crops.length && k < reads.length; k++) {
        if (crops[k].role == role && crops[k].index == i) return reads[k];
      }
      return const [];
    }

    // The new national plate's hatched, pale characters break apart in the
    // image, but the whole-area OCR reads its one line well ("AAAGO00").
    if (seg.code == null) {
      final national = PlateArranger(parser: parser).nationalFromOcr(ocr);
      if (national != null) return national;
    }

    // Section 3: a vote over the whole-number reads (they rarely disagree);
    // single-digit reads only fill positions the vote leaves open.
    final n = seg.numberChars.length;
    final perDigit = [
      for (var i = 0; i < n; i++)
        _majority(
          readsOf('digit', i).map((t) => _single(t, _toDigit, digit: true)),
        ),
    ];
    // The new national plate (ETH, 2026): no circle, no region letters, and
    // the number is three letters and four digits ("ABC1234").
    final national = seg.code == null && seg.latinStack.isEmpty
        ? _majority(readsOf('number', 0)
            .map((t) => t == null ? null : parser.readNationalSerial(t)))?.$1
        : null;
    final number = national ??
        _voteNumber(_numberReads(readsOf('number', 0)), perDigit, n) ??
        '';
    // Boxes per digit: the segmentation's when the counts match, else the
    // number box divided evenly (two touching digits found as one shape).
    final nb = seg.number!;
    final boxes = number.length == n
        ? seg.numberChars
        : [
            for (var i = 0; i < number.length; i++)
              NormalizedRect(
                nb.left + nb.width * i / number.length,
                nb.top,
                nb.left + nb.width * (i + 1) / number.length,
                nb.bottom,
              ),
          ];
    final numberSection = PlateSection(
      kind: PlateSectionKind.number,
      value: number,
      chars: [
        for (var i = 0; i < number.length; i++) PlateChar(number[i], boxes[i]),
      ],
      box: seg.number,
      detected: number.isNotEmpty,
    );

    // Section 4: each stacked letter read alone, top to bottom.
    var letters = [
      for (var i = 0; i < seg.latinStack.length; i++)
        _letter(readsOf('latin', i)),
    ];
    // The two letters read side by side as one word fill or confirm them.
    final word = _majority(readsOf('latinWord', 0).map(_twoLetters));
    if (word != null && letters.length == 2) {
      for (var i = 0; i < 2; i++) {
        letters[i] =
            letters[i] == null || word.$2 >= 2 ? word.$1[i] : letters[i];
      }
    }
    // Strict reading incomplete or no region: try lenient readings (a single
    // digit-for-letter vote, the font's U/N look-alikes) and keep one only
    // if it names a region or a special plate.
    bool known(String v) =>
        parser.readRegion(v) != null || _specials.contains(v);
    final strict = letters.every((l) => l != null) ? letters.join() : null;
    if (letters.isNotEmpty && (strict == null || !known(strict))) {
      final lenient = [
        for (var i = 0; i < seg.latinStack.length; i++)
          letters[i] ?? _letter(readsOf('latin', i), minMapped: 1),
      ];
      if (lenient.every((l) => l != null)) {
        for (final v in _lookAlikes(lenient.join())) {
          if (known(v)) {
            letters = v.split('');
            break;
          }
        }
      }
    }
    final latinValue =
        letters.any((l) => l == null) ? '' : letters.whereType<String>().join();
    final latinBox = seg.latinStack.isEmpty
        ? null
        : seg.latinStack.reduce((a, b) => a.union(b));
    var latinSection = PlateSection(
      kind: PlateSectionKind.latinRegion,
      value: latinValue,
      chars: [
        for (var i = 0; i < seg.latinStack.length; i++)
          PlateChar(letters[i] ?? '?', seg.latinStack[i]),
      ],
      box: latinBox,
      detected: latinValue.isNotEmpty,
    );

    // Section 2: located, not read; spelled from section 4's region.
    final geezBox = seg.geezStack.isEmpty
        ? null
        : seg.geezStack.reduce((a, b) => a.union(b));
    var geezSection = PlateArranger(parser: parser).geezFromLatin(
      PlateSection(
        kind: PlateSectionKind.geezRegion,
        value: PlateSection.geezPlaceholder,
        box: geezBox,
        detected: false,
      ),
      latinValue,
      boxes: seg.geezStack,
    );

    // Section 1: the digit inside the circle, then the shared code rules.
    final circle = _majority([
      ...readsOf('code', 0).map((t) => _single(t, _toDigit, digit: true)),
      ...readsOf('codeRepeat', 0).map(_repeatedDigit),
    ]);
    final circleDigit =
        PlateServiceType.isKnown(circle?.$1) ? circle!.$1 : null;
    // Section 4 decided by the plate's layout when its letters weren't read.
    PlateSection latinByLayout(String v) => PlateSection(
          kind: PlateSectionKind.latinRegion,
          value: v,
          chars: [
            if (seg.latinStack.length == 2)
              for (var i = 0; i < 2; i++) PlateChar(v[i], seg.latinStack[i]),
          ],
          box: latinBox,
          note: 'by layout',
        );

    // Plates without a circle (section 1 is something else):
    // - diplomatic: the embassy number's big digits left of the Ge'ez (never
    //   two on the 1–5 plates logged); C/D on its yellow strip is often
    //   misread, and the strip must not pass for a police plate;
    // - police: yellow plate, or ፖሊስ in black left of the Ge'ez stack;
    // - temporary: ተላላፊ in light blue left of the Ge'ez stack;
    // - UN / AU: የተመ / አሕ and no Ge'ez stack; AU's letters side by side.
    // Section 4 naming a region rules out UN and AU (a crop that cut the
    // circle off leaves a stray "word").
    final noCircle = seg.code == null;
    final diplomatic = noCircle && seg.leftDigits.length >= 2;
    final hasWord = noCircle && _isWord(seg);
    final isRegion = parser.readRegion(latinValue) != null;
    String? special = national != null
        ? PlateServiceType.national.code
        : _specials.contains(latinValue)
            ? latinValue
            : null;
    if (special == null && diplomatic) special = 'CD';
    final paper = ocr.paperColor;
    if (special == null &&
        paper != null &&
        paper.length == 3 &&
        PaperColor.isYellow(paper[0], paper[1], paper[2])) {
      special = PlateServiceType.police.code;
    }
    if (special == null && hasWord && !isRegion && seg.latinSideBySide) {
      special = PlateServiceType.africanUnion.code;
    }
    if (special == null &&
        hasWord &&
        !isRegion &&
        seg.geezStack.isEmpty &&
        seg.numberChars.length == 7) {
      special = PlateServiceType.unitedNations.code;
    }
    if (special == null && hasWord && seg.geezStack.isNotEmpty) {
      final ink = ocr.inkColor;
      final blue = ink != null && ink.length == 3 && ink[2] - ink[0] >= 40;
      special =
          blue ? PlateServiceType.temporary.code : PlateServiceType.police.code;
    }
    if ({'CD', 'UN', 'AU'}.contains(special) && latinValue != special) {
      latinSection = latinByLayout(special!);
    }
    // UN, AU and the new national plates carry no Ge'ez region: their
    // Ge'ez is section 1 (the national plate has no region at all).
    if (special == 'UN' || special == 'AU' || national != null) {
      geezSection = PlateSection(
        kind: PlateSectionKind.geezRegion,
        value: '',
        detected: false,
        note: 'none on $special plates',
      );
    }
    if (national != null) {
      latinSection = PlateSection(
        kind: PlateSectionKind.latinRegion,
        value: '',
        detected: false,
        note: 'none on $special plates',
      );
    }
    String? embassy;
    if (special == 'CD' && seg.leftDigits.isNotEmpty) {
      // Per digit: its own reads and that position of the whole-number
      // reads that have one digit per shape.
      final words = readsOf('embassyWord', 0)
          .map(_digits)
          .where((w) =>
              w.length == seg.leftDigits.length &&
              RegExp(r'^[0-9]+$').hasMatch(w))
          .toList();
      final e = [
        for (var i = 0; i < seg.leftDigits.length; i++)
          _majority([
            ...readsOf('embassy', i)
                .map((t) => _single(t, _toDigit, digit: true)),
            for (final w in words) w[i],
          ])?.$1,
      ];
      if (e.every((d) => d != null)) embassy = e.join();
    }
    final codeSection = PlateArranger(parser: parser).codeSection(
      // The circle crop (2+ of 3 reads agreeing) counts as a strong read;
      // otherwise the whole-area circle pass.
      hint: circleDigit ?? ocr.codeHint,
      votes: circleDigit != null ? (circle!.$2 >= 2 ? 3 : 1) : ocr.codeVotes,
      // No circle: section 1 is the embassy number, or the Ge'ez word (on
      // the national plate, the ኢት / ETH block found as stacks).
      box: seg.code ??
          (national != null && seg.geezStack.isNotEmpty
              ? seg.geezStack.reduce((a, b) => a.union(b))
              : null) ??
          (special == 'CD' && seg.leftDigits.isNotEmpty
              ? seg.leftDigits.reduce((a, b) => a.union(b))
              : special != null && seg.leftWord.isNotEmpty
                  ? seg.leftWord.reduce((a, b) => a.union(b))
                  : null),
      ink: ocr.inkColor,
      special: special,
      embassy: embassy,
    );

    final arrangement = PlateArrangement(
      code: codeSection,
      geezRegion: geezSection,
      number: numberSection,
      latinRegion: latinSection,
    );
    final code = codeSection.value.isEmpty ? null : codeSection.value;
    final region = parser.readRegion(latinValue);
    final serial = numberSection.value.isEmpty ? null : numberSection.value;
    final candidate = PlateCandidate(
      code: code,
      regionCode: region?.code,
      serial: serial,
      layout: seg.twoRow ? PlateLayout.twoRow : PlateLayout.singleRow,
      rawText: arrangement.layoutText,
      confidence: _confidence(number, letters),
      issues: parser.validate(
        code: code,
        regionCode: region?.code,
        serial: serial,
      ),
    );
    return (arrangement: arrangement, candidate: candidate);
  }

  /// The whole-number reads as digits. A read one character longer than
  /// the most common length has a neighbour glued on (the A/A stack read
  /// as "1": "BO5475" + "1"); without its last character it votes too —
  /// mapped again, since the extra character changes how a leading letter
  /// is taken (session logs: B05475).
  static List<String> _numberReads(List<String?> raw) {
    final mapped = raw.map(_digits).toList();
    final lengths =
        _majority(mapped.where((m) => m.length >= 4).map((m) => '${m.length}'));
    if (lengths == null) return mapped;
    final common = int.parse(lengths.$1);
    String trimmed(int i) {
      final clean = raw[i]!.replaceAll(RegExp(r'[^0-9A-Za-z|]'), '');
      return clean.length > common
          ? _digits(clean.substring(0, common))
          : mapped[i];
    }

    return [
      for (var i = 0; i < mapped.length; i++)
        mapped[i].length == common + 1 ? trimmed(i) : mapped[i],
    ];
  }

  /// Whether [seg]'s shapes left of section 2 are a Ge'ez word (ፖሊስ,
  /// ተላላፊ, የተመ, አሕ): two or more letter-sized shapes (0.3–0.6 of a digit)
  /// over at least 1.5 digit pitches. A broken circle or the stub of a cut
  /// stack is not (session logs: words span 1.7–3.3 pitches).
  static bool _isWord(PlateSegmentation seg) {
    final word = seg.leftWord, digits = seg.numberChars;
    if (word.length < 2 || digits.isEmpty) return false;
    final heights = [for (final d in digits) d.height]..sort();
    final hd = heights[heights.length ~/ 2];
    final pitch = seg.number!.width / digits.length;
    final letters =
        word.where((r) => r.height >= hd * 0.3 && r.height <= hd * 0.6);
    return letters.length >= 2 &&
        word.last.right - word.first.left >= pitch * 1.5;
  }

  /// The number agreed by at least two of [reads] (5–8 digits each); else a
  /// per-position vote among reads of the most common length, with an open
  /// position filled only by a [perDigit] read; null when undecided.
  static String? _voteNumber(
    List<String> reads,
    List<(String, int)?> perDigit,
    int segmented,
  ) {
    final usable = reads.where((r) => r.length >= 4 && r.length <= 8).toList();
    final whole = _majority(usable);
    if (whole != null && whole.$2 >= 2) return whole.$1;
    if (usable.isEmpty) {
      // Nothing from the line: all single digits must be read.
      if (perDigit.isEmpty || perDigit.any((d) => d == null)) return null;
      return perDigit.map((d) => d!.$1).join();
    }
    final lengths = _majority(usable.map((r) => '${r.length}'));
    final length = lengths == null
        ? (usable.any((r) => r.length == segmented)
            ? segmented
            : usable.first.length)
        : int.parse(lengths.$1);
    final same = usable.where((r) => r.length == length).toList();
    final out = StringBuffer();
    for (var i = 0; i < length; i++) {
      final v = _majority(same.map((r) => r[i]));
      final d = length == perDigit.length ? perDigit[i] : null;
      if (v != null && same.length == 1 && d != null && d.$2 == 3) {
        // One line read against three agreeing single-digit reads.
        out.write(d.$1);
      } else if (v != null && (v.$2 >= 2 || same.length == 1)) {
        out.write(v.$1);
      } else if (length == perDigit.length && perDigit[i] != null) {
        out.write(perDigit[i]!.$1);
      } else {
        return null;
      }
    }
    return out.toString();
  }

  /// One letter from a crop's reads: a letter read as such counts once; a
  /// digit taken for a letter (`1` → `I`) needs two agreeing reads.
  static String? _letter(List<String?> reads, {int minMapped = 2}) {
    final native = <String?>[];
    final mapped = <String?>[];
    for (final t in reads) {
      final plain = _single(t, const {}, digit: false);
      if (plain != null) {
        native.add(plain);
      } else {
        mapped.add(_single(t, _toLetter, digit: false));
      }
    }
    final n = _majority(native);
    if (n != null) return n.$1;
    final m = _majority(mapped);
    return m != null && m.$2 >= minMapped ? m.$1 : null;
  }

  /// [value] and its variants with the plate font's look-alike letters.
  static Iterable<String> _lookAlikes(String value) sync* {
    const alike = {'N': 'U', 'U': 'N', 'F': 'E', 'E': 'F'};
    yield value;
    for (var i = 0; i < value.length; i++) {
      final alt = alike[value[i]];
      if (alt != null) {
        yield value.substring(0, i) + alt + value.substring(i + 1);
      }
    }
  }

  /// The one character in [text] after dropping noise, mapped by [map] when
  /// it is not already of the wanted kind; null if not exactly one.
  static String? _single(
    String? text,
    Map<String, String> map, {
    required bool digit,
  }) {
    if (text == null) return null;
    final chars = text
        .split('')
        .where((c) => c.trim().isNotEmpty && !_noise.contains(c))
        .map((c) {
      final isDigit = RegExp(r'[0-9]').hasMatch(c);
      if (digit == isDigit) return c.toUpperCase();
      return map[c] ?? map[c.toUpperCase()] ?? c.toUpperCase();
    }).toList();
    if (chars.length != 1) return null;
    final c = chars.first;
    final ok =
        digit ? RegExp(r'^[0-9]$').hasMatch(c) : RegExp(r'^[A-Z]$').hasMatch(c);
    return ok ? c : null;
  }

  /// Two letters read as one word ("ET", "0R" -> "OR"), or null.
  static String? _twoLetters(String? text) {
    if (text == null) return null;
    final chars = text
        .split('')
        .where((c) => c.trim().isNotEmpty && !_noise.contains(c))
        .map((c) => _toLetter[c] ?? c.toUpperCase())
        .toList();
    if (chars.length != 2) return null;
    return chars.every((c) => RegExp(r'^[A-Z]$').hasMatch(c))
        ? chars.join()
        : null;
  }

  /// The digit read in a crop drawn three times ("444" -> "4"): at least two
  /// copies read and all the same.
  static String? _repeatedDigit(String? text) {
    if (text == null) return null;
    final chars = text
        .split('')
        .where((c) => c.trim().isNotEmpty && !_noise.contains(c))
        .map((c) => RegExp(r'[0-9]').hasMatch(c) ? c : (_toDigit[c] ?? c))
        .toList();
    if (chars.length < 2 || chars.any((c) => c != chars.first)) return null;
    return RegExp(r'^[0-9]$').hasMatch(chars.first) ? chars.first : null;
  }

  /// Digits in [text], letters read for digits mapped, noise dropped. A
  /// leading Latin letter before five digits is a series letter and kept
  /// (`C06703`, `B88418`); before six it is the plate font's notched 0
  /// read as a letter (`G123456`).
  static String _digits(String? text) {
    if (text == null) return '';
    final kept = text
        .split('')
        .where((c) => RegExp(r'[0-9A-Za-z|]').hasMatch(c))
        .toList();
    if (kept.length == 6 &&
        RegExp(r'^[A-Z]$').hasMatch(kept.first) &&
        kept.skip(1).every(
            (c) => RegExp(r'[0-9]').hasMatch(c) || _toDigit.containsKey(c))) {
      return kept.first + _digits(kept.skip(1).join());
    }
    final out = StringBuffer();
    for (final c in text.split('')) {
      if (RegExp(r'[0-9]').hasMatch(c)) {
        out.write(c);
      } else if (_toDigit.containsKey(c)) {
        out.write(_toDigit[c]);
      }
    }
    return out.toString();
  }

  /// Most frequent non-null value and its count; null on a tie or nothing.
  static (String, int)? _majority(Iterable<String?> values) {
    final counts = <String, int>{};
    for (final v in values) {
      if (v != null) counts[v] = (counts[v] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final top = counts.values.reduce((a, b) => a > b ? a : b);
    final winners = counts.entries.where((e) => e.value == top).toList();
    return winners.length == 1 ? (winners.first.key, top) : null;
  }

  static double _confidence(String number, List<String?> letters) {
    final parts = [
      if (number.isNotEmpty) 1.0 else 0.0,
      for (final l in letters) l == null ? 0.0 : 1.0,
    ];
    return parts.reduce((a, b) => a + b) / parts.length;
  }
}
