import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../segmentation/plate_segmenter.dart';
import 'ethiopian_plate_parser.dart';
import 'plate_arranger.dart';
import 'plate_service_type.dart';

/// One crop to read and what it is for.
class SectionCrop {
  /// Creates a crop request.
  const SectionCrop(this.role, this.index, this.box, this.inArea);

  /// `number`, `digit`, `latin`, `code` or `embassy`.
  final String role;

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
    'Z': '2', 'z': '2', 'S': '5', 's': '5', 'B': '8', 'G': '6',
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
  List<SectionCrop> cropsFor(PlateSegmentation seg, NormalizedRect area) {
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
      if (seg.geezStack.isNotEmpty) {
        final g =
            seg.geezStack.map((r) => r.right).reduce((a, b) => a > b ? a : b);
        if (left < (g + number.left) / 2) left = (g + number.left) / 2;
      }
      if (seg.latinStack.isNotEmpty) {
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
    for (var i = 0; i < seg.numberChars.length; i++) {
      out.add(crop('digit', i, pad(seg.numberChars[i], 0.15, 0.08)));
    }
    for (var i = 0; i < seg.latinStack.length; i++) {
      out.add(crop('latin', i, pad(seg.latinStack[i], 0.2, 0.15)));
    }
    final inner = seg.codeInner ?? seg.code;
    if (inner != null) out.add(crop('code', 0, pad(inner, 0.25, 0.15)));
    for (var i = 0; i < seg.leftDigits.length; i++) {
      out.add(crop('embassy', i, pad(seg.leftDigits[i], 0.15, 0.08)));
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

    // Section 3: per-digit majority, checked against the whole-number read.
    final n = seg.numberChars.length;
    final perDigit = [
      for (var i = 0; i < n; i++)
        _majority(
            readsOf('digit', i).map((t) => _single(t, _toDigit, digit: true))),
    ];
    String? line;
    for (final t in readsOf('number', 0)) {
      final d = _digits(t);
      if (d.length == n) {
        line = d;
        break;
      }
    }
    final digits = <String>[];
    for (var i = 0; i < n; i++) {
      final p = perDigit[i];
      final fromLine = line?[i];
      // The line read knows context; a confident per-digit read overrides.
      digits.add(p != null && p.$2 >= 2 ? p.$1 : (fromLine ?? p?.$1 ?? '?'));
    }
    final number = digits.join();
    final numberSection = PlateSection(
      kind: PlateSectionKind.number,
      value: number.contains('?') ? '' : number,
      chars: [
        for (var i = 0; i < n; i++) PlateChar(digits[i], seg.numberChars[i]),
      ],
      box: seg.number,
      detected: !number.contains('?') && n > 0,
    );

    // Section 4: each stacked letter read alone, top to bottom.
    final letters = [
      for (var i = 0; i < seg.latinStack.length; i++)
        _majority(readsOf('latin', i)
            .map((t) => _single(t, _toLetter, digit: false)))?.$1,
    ];
    final latinValue =
        letters.any((l) => l == null) ? '' : letters.whereType<String>().join();
    final latinBox = seg.latinStack.isEmpty
        ? null
        : seg.latinStack.reduce((a, b) => a.union(b));
    final latinSection = PlateSection(
      kind: PlateSectionKind.latinRegion,
      value: latinValue,
      chars: [
        for (var i = 0; i < seg.latinStack.length; i++)
          PlateChar(letters[i] ?? '?', seg.latinStack[i]),
      ],
      box: latinBox,
      detected: latinValue.isNotEmpty,
    );

    // Section 2: located, not read.
    final geezBox = seg.geezStack.isEmpty
        ? null
        : seg.geezStack.reduce((a, b) => a.union(b));
    final geezSection = PlateSection(
      kind: PlateSectionKind.geezRegion,
      value: PlateSection.geezPlaceholder,
      box: geezBox,
      detected: false,
    );

    // Section 1: the digit inside the circle, then the shared code rules.
    final circle = _majority(
        readsOf('code', 0).map((t) => _single(t, _toDigit, digit: true)));
    final circleDigit =
        PlateServiceType.isKnown(circle?.$1) ? circle!.$1 : null;
    String? special = _specials.contains(latinValue) ? latinValue : null;
    final paper = ocr.paperColor;
    if (special == null &&
        paper != null &&
        paper.length == 3 &&
        PaperColor.isYellow(paper[0], paper[1], paper[2])) {
      special = PlateServiceType.police.code;
    }
    String? embassy;
    if (special == 'CD' && seg.leftDigits.isNotEmpty) {
      final e = [
        for (var i = 0; i < seg.leftDigits.length; i++)
          _majority(readsOf('embassy', i)
              .map((t) => _single(t, _toDigit, digit: true)))?.$1,
      ];
      if (e.every((d) => d != null)) embassy = e.join();
    }
    final codeSection = PlateArranger(parser: parser).codeSection(
      // The circle crop (2+ of 3 reads agreeing) counts as a strong read;
      // otherwise the whole-area circle pass.
      hint: circleDigit ?? ocr.codeHint,
      votes: circleDigit != null ? (circle!.$2 >= 2 ? 3 : 1) : ocr.codeVotes,
      box: seg.code,
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
      layout: PlateLayout.singleRow,
      rawText: arrangement.layoutText,
      confidence: _confidence(perDigit, letters, line != null),
      issues: parser.validate(
        code: code,
        regionCode: region?.code,
        serial: serial,
      ),
    );
    return (arrangement: arrangement, candidate: candidate);
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

  /// Digits in [text], letters read for digits mapped, noise dropped.
  static String _digits(String? text) {
    if (text == null) return '';
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

  static double _confidence(
    List<(String, int)?> digits,
    List<String?> letters,
    bool lineAgreed,
  ) {
    final parts = [
      for (final d in digits) d == null ? 0.0 : d.$2 / 3,
      for (final l in letters) l == null ? 0.0 : 1.0,
      if (lineAgreed) 1.0,
    ];
    if (parts.isEmpty) return 0;
    return parts.reduce((a, b) => a + b) / parts.length;
  }
}
