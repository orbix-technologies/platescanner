import '../models/ocr_frame.dart';
import '../models/plate_record.dart';
import 'ethiopian_region.dart';
import 'plate_service_type.dart';

/// Turns OCR lines into a validated [PlateCandidate].
///
/// Pure Dart (no Flutter imports) so every rule is unit-testable. The parser
/// expects lines already cropped to the plate / guide region.
class EthiopianPlateParser {
  /// Creates a parser.
  ///
  /// When [requireRegion] is true, numeric-code plates without a region are
  /// reported with [PlateIssue.missingRegion]. Special plates (CD, AU, UN,
  /// police) never require one.
  const EthiopianPlateParser({this.requireRegion = true});

  /// Whether numeric-code plates must carry a region.
  final bool requireRegion;

  /// Serial: five digits with an optional Latin letter prefix (older plates),
  /// or six / seven digits (new Ge'ez-format plates).
  static final serialPattern = RegExp(r'^([A-Z]?\d{5}|\d{6,7})$');

  /// Serial of the new national plate: three letters, four digits, e.g.
  /// `ABC1234` (motorcycles reportedly may have three digits: unconfirmed).
  static final nationalSerialPattern = RegExp(r'^[A-Z]{3}\d{4}$');

  // Ge'ez is never read: the region comes from its Latin letters only, so
  // Ge'ez characters split tokens like punctuation.
  static final _splitter = RegExp(r'[^A-Za-z0-9]+');
  static final _latinLetter = RegExp(r'^[A-Z]$');
  static const _ignored = {'ETHIOPIA', 'ETH'};
  static final _circled = RegExp('[\u2460-\u2464]');

  // Common OCR confusions on plate fonts.
  static const _toDigit = {
    'O': '0', 'Q': '0', 'D': '0', 'U': '0', //
    'I': '1', 'L': '1', 'J': '1', 'T': '1', '|': '1',
    'Z': '2', 'S': '5', 'B': '8', 'G': '6',
  };
  static const _toLetter = {
    '0': 'O',
    '1': 'I',
    '2': 'Z',
    '5': 'S',
    '8': 'B',
    '6': 'G',
    '4': 'A',
  };

  /// Parses [lines] (any order) into a candidate.
  ///
  /// [codeHint] is a service code read by a separate pass (the circled code
  /// on new-format plates); it is used when no code is read from [lines].
  PlateCandidate parse(List<OcrLine> lines, {String? codeHint}) {
    final sorted = [...lines]..sort((a, b) {
        final dy = a.box.centerY - b.box.centerY;
        if (dy.abs() > 0.02) return dy.sign.toInt();
        return a.box.left.compareTo(b.box.left);
      });

    final tokens = <_Token>[];
    for (var i = 0; i < sorted.length; i++) {
      // Circled digits (①–⑤) are the code on new-format plates.
      final text = sorted[i].text.replaceAllMapped(
            _circled,
            (m) => ' ${m[0]!.codeUnitAt(0) - 0x245F} ',
          );
      for (final part in text.split(_splitter)) {
        if (part.isEmpty) continue;
        final upper = part.toUpperCase();
        if (_ignored.contains(upper)) continue;
        tokens.add(_Token(upper, i, tokens.length));
      }
    }

    final rawText = sorted.map((l) => l.text).join('\n');
    final serialHit = _findSerial(tokens);
    final used = <int>{...?serialHit?.tokenIndexes};

    final hint = PlateServiceType.isKnown(codeHint) ? codeHint : null;
    var corrections = serialHit?.corrections ?? 0;
    String? code = serialHit?.mergedCode;
    if (code == null) {
      final codeHit = _findCode(tokens, used, serialHit);
      // A letter read as a digit loses to the dedicated code pass.
      if (codeHit != null && (codeHit.corrections == 0 || hint == null)) {
        code = codeHit.value;
        corrections += codeHit.corrections;
        used.add(codeHit.tokenIndex);
      } else if (hint != null) {
        code = hint;
      }
    }
    // Old plates sometimes merge the code box into the serial ("212345").
    var serial = serialHit?.value;
    final alt = serialHit?.mergedAlternative;
    if (code == null && alt != null) {
      code = alt.$1;
      serial = alt.$2;
    }

    String? regionCode;
    final regionHit =
        _findRegion(tokens, used) ?? _findStackedRegion(tokens, used, sorted);
    if (regionHit != null) {
      regionCode = regionHit.region.code;
      corrections += regionHit.corrections;
    }

    final issues = validate(code: code, regionCode: regionCode, serial: serial);

    final confidences =
        sorted.map((l) => l.confidence).whereType<double>().toList();
    final ocrConfidence = confidences.isEmpty
        ? 0.8
        : confidences.reduce((a, b) => a + b) / confidences.length;
    var confidence = ocrConfidence;
    for (var i = 0; i < corrections; i++) {
      confidence *= 0.95;
    }
    if (issues.isNotEmpty) confidence *= 0.5;

    NormalizedRect? box;
    for (final l in sorted) {
      box = box == null ? l.box : box.union(l.box);
    }

    return PlateCandidate(
      code: code,
      regionCode: regionCode,
      serial: serial,
      layout: _layout(sorted, serialHit),
      rawText: rawText,
      confidence: confidence.clamp(0.0, 1.0),
      issues: issues,
      boundingBox: box,
    );
  }

  /// Validates field values (used for parsed and user-edited readings).
  List<PlateIssue> validate({
    String? code,
    String? regionCode,
    String? serial,
  }) {
    final issues = <PlateIssue>[];
    final type = PlateServiceType.fromCode(code);
    if (code == null || code.isEmpty) {
      issues.add(PlateIssue.missingCode);
    } else if (type == null) {
      issues.add(PlateIssue.unknownCode);
    }
    final numeric = type != null && int.tryParse(type.code) != null;
    final hasRegion = EthiopianRegion.fromCode(regionCode) != null;
    if (!hasRegion && requireRegion && (numeric || type == null)) {
      issues.add(PlateIssue.missingRegion);
    }
    // Diplomatic plates carry a four-digit number.
    final diplomatic = type == PlateServiceType.diplomatic &&
        serial != null &&
        RegExp(r'^\d{4}$').hasMatch(serial);
    final national = type == PlateServiceType.national &&
        serial != null &&
        nationalSerialPattern.hasMatch(serial);
    if (serial == null ||
        (!serialPattern.hasMatch(serial) && !diplomatic && !national)) {
      issues.add(PlateIssue.missingSerial);
    }
    return issues;
  }

  /// Reads one token as a serial, correcting common OCR confusions.
  ///
  /// `mergedCode` is set when a code digit was fused onto the front
  /// (`2A12345`); `alternative` is a (code, serial) split to use only when no
  /// code is found elsewhere (`212345`).
  ({
    String serial,
    String? mergedCode,
    (String, String)? alternative,
    int corrections,
  })? readSerial(String token) {
    final hit = _serialFrom(token.toUpperCase(), const []);
    if (hit == null) return null;
    return (
      serial: hit.value,
      mergedCode: hit.mergedCode,
      alternative: hit.mergedAlternative,
      corrections: hit.corrections,
    );
  }

  /// Reads one token as a new national number (`ABC1234`): three letters
  /// as read, then four digits, where a letter read in a digit place is
  /// mapped to its digit (the plate font's notched 0 is read as `G`, `O`,
  /// `D`, `Q` or `C`). Old serials misread can look alike (`C06703` read
  /// `CO67038` or `OCO670`), so all three must be read as letters and one
  /// at least must not be a digit look-alike. Null otherwise.
  String? readNationalSerial(String token) {
    final t = token.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (t.length != 7) return null;
    final head = t.substring(0, 3), tail = t.substring(3);
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(head)) return null;
    if (head.split('').every(_nationalDigit.containsKey)) return null;
    final digits = tail.split('').map((c) => _nationalDigit[c] ?? c).join();
    final serial = head + digits;
    return nationalSerialPattern.hasMatch(serial) ? serial : null;
  }

  static const _nationalDigit = {
    'O': '0', 'Q': '0', 'D': '0', 'G': '0', 'C': '0', 'U': '0', //
    'I': '1', 'L': '1', 'Z': '2', 'S': '5', 'B': '8',
  };

  /// Reads one token as a service code (`1`–`5`, `CD`, `AU`, `UN`, `POLICE`),
  /// correcting a letter read for a digit (`I` → `1`). Returns `null` otherwise.
  String? readCode(String token) {
    final t = token.toUpperCase();
    final special = PlateServiceType.fromCode(t);
    if (special != null) return special.code;
    if (t.length != 1) return null;
    final digit = _isDigit(t) ? t : _toDigit[t];
    return PlateServiceType.isKnown(digit) ? digit : null;
  }

  /// Reads Latin letters as a region (`AA`, `OM`, `0R` → `OR`), or `null`.
  EthiopianRegion? readRegion(String token) {
    final t = token.toUpperCase();
    return EthiopianRegion.fromLatin(t) ??
        EthiopianRegion.fromLatin(
          t.split('').map((c) => _toLetter[c] ?? c).join(),
        );
  }

  /// Normalises a user-typed serial (`a 12345` → `A12345`), or `null`.
  String? normalizeSerial(String input) {
    final s = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return serialPattern.hasMatch(s) ? s : null;
  }

  /// Formats a record for display, e.g. `2 · AA · A12345`.
  String format(PlateRecord record) => [
        record.code,
        if (record.regionCode != null) record.regionCode!,
        record.serial,
      ].join(' · ');

  _SerialHit? _findSerial(List<_Token> tokens) {
    _SerialHit? best;
    void consider(_SerialHit? hit) {
      if (hit == null) return;
      if (best == null || hit.score > best!.score) best = hit;
    }

    for (var i = 0; i < tokens.length; i++) {
      consider(_serialFrom(tokens[i].text, [i]));
      // Serial split by OCR into two tokens on the same line ("A 12345").
      if (i + 1 < tokens.length && tokens[i + 1].line == tokens[i].line) {
        consider(_serialFrom(tokens[i].text + tokens[i + 1].text, [i, i + 1]));
      }
    }
    return best;
  }

  _SerialHit? _serialFrom(String s, List<int> indexes) {
    if (s.length < 5 || s.length > 8) return null;

    (String, int)? digits(String part) {
      final buf = StringBuffer();
      var fixes = 0;
      for (final ch in part.split('')) {
        if (_isDigit(ch)) {
          buf.write(ch);
        } else if (_toDigit.containsKey(ch)) {
          buf.write(_toDigit[ch]);
          fixes++;
        } else {
          return null;
        }
      }
      // Too many guessed digits — more likely a word than a serial.
      return fixes > 2 ? null : (buf.toString(), fixes);
    }

    final joined = indexes.length > 1 ? 1 : 0;
    final first = s[0];
    final firstIsCode = _isDigit(first) && PlateServiceType.isKnown(first);

    // Letter + 5 digits (older plates).
    if (s.length == 6 && _latinLetter.hasMatch(first)) {
      final tail = digits(s.substring(1));
      if (tail != null && _isDigit(s[1])) {
        return _SerialHit(
            '$first${tail.$1}', indexes, tail.$2, null, 12 - tail.$2 - joined);
      }
    }
    // Code digit + letter + 5 digits merged ("2A12345").
    if (s.length == 7 && firstIsCode && _latinLetter.hasMatch(s[1])) {
      final tail = digits(s.substring(2));
      if (tail != null) {
        return _SerialHit(
            '${s[1]}${tail.$1}', indexes, tail.$2, first, 9 - tail.$2);
      }
    }
    // 5–7 digits; the leading digit may be a merged code ("212345").
    if (!_isDigit(first) && !_isDigit(s[s.length - 1])) return null;
    final all = digits(s);
    if (all == null) return null;
    final n = all.$1.length;
    (String, String)? alt;
    if (firstIsCode && n >= 6) {
      alt = (first, all.$1.substring(1));
    }
    if (n > 7) {
      return alt == null
          ? null
          : _SerialHit(alt.$2, indexes, all.$2, alt.$1, 9 - all.$2);
    }
    return _SerialHit(all.$1, indexes, all.$2, null, 10 - all.$2 - joined,
        mergedAlternative: alt);
  }

  _CodeHit? _findCode(List<_Token> tokens, Set<int> used, _SerialHit? serial) {
    _CodeHit? best;
    final serialLine =
        serial == null ? null : tokens[serial.tokenIndexes.first].line;
    for (final t in tokens) {
      if (used.contains(t.index)) continue;
      final special = PlateServiceType.fromCode(t.text);
      if (special != null && int.tryParse(special.code) == null) {
        return _CodeHit(special.code, t.index, 0);
      }
      if (t.text.length != 1) continue;
      var value = t.text;
      var fixes = 0;
      if (!_isDigit(value)) {
        final mapped = _toDigit[value];
        if (mapped == null) continue;
        value = mapped;
        fixes = 1;
      }
      if (!PlateServiceType.isKnown(value)) continue;
      // Prefer a code on the serial's line or the line above it.
      final near = serialLine == null || (t.line - serialLine).abs() <= 1;
      final hit = _CodeHit(value, t.index, fixes, near: near);
      if (best == null || hit.rank > best.rank) best = hit;
    }
    return best;
  }

  _RegionHit? _findRegion(List<_Token> tokens, Set<int> used) {
    for (final t in tokens) {
      if (used.contains(t.index)) continue;
      final direct = EthiopianRegion.fromLatin(t.text);
      if (direct != null) return _RegionHit(direct, 0);
    }
    for (final t in tokens) {
      if (used.contains(t.index) || t.text.length > 4) continue;
      final asLetters = t.text.split('').map((c) => _toLetter[c] ?? c).join();
      if (asLetters == t.text) continue;
      final fixed = EthiopianRegion.fromLatin(asLetters);
      if (fixed != null) return _RegionHit(fixed, 1);
    }
    return null;
  }

  /// Region printed as letters stacked vertically (new plates: `A` over `A`,
  /// `አ` over `አ`), which OCR returns as separate one-letter lines.
  _RegionHit? _findStackedRegion(
    List<_Token> tokens,
    Set<int> used,
    List<OcrLine> lines,
  ) {
    final singles = tokens
        .where((t) => !used.contains(t.index) && t.text.runes.length == 1)
        .toList();
    for (var i = 0; i < singles.length; i++) {
      for (var j = i + 1; j < singles.length; j++) {
        final a = singles[i];
        final b = singles[j];
        final boxA = lines[a.line].box;
        final boxB = lines[b.line].box;
        final sameLine = a.line == b.line && b.index == a.index + 1;
        final stacked = a.line != b.line &&
            (boxA.centerX - boxB.centerX).abs() <
                (boxA.width > boxB.width ? boxA.width : boxB.width);
        if (!sameLine && !stacked) continue;
        final pair = a.text + b.text;
        final region = EthiopianRegion.fromLatin(pair);
        if (region != null) return _RegionHit(region, 0);
      }
    }
    return null;
  }

  PlateLayout _layout(List<OcrLine> sorted, _SerialHit? serial) {
    if (serial == null || sorted.isEmpty) return PlateLayout.unknown;
    final rows = <double>[];
    for (final l in sorted) {
      final tol = l.box.height * 0.6;
      if (!rows.any((y) => (y - l.box.centerY).abs() <= tol)) {
        rows.add(l.box.centerY);
      }
    }
    return rows.length >= 2 ? PlateLayout.twoRow : PlateLayout.singleRow;
  }

  static bool _isDigit(String ch) {
    final c = ch.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39;
  }
}

class _Token {
  _Token(this.text, this.line, this.index);
  final String text;
  final int line;
  final int index;
}

class _SerialHit {
  _SerialHit(
    this.value,
    this.tokenIndexes,
    this.corrections,
    this.mergedCode,
    this.score, {
    this.mergedAlternative,
  });

  /// (code, serial) if the first digit is really a merged code box; used only
  /// when no code is found elsewhere.
  final (String, String)? mergedAlternative;
  final String value;
  final List<int> tokenIndexes;
  final int corrections;
  final String? mergedCode;
  final int score;
}

class _CodeHit {
  _CodeHit(this.value, this.tokenIndex, this.corrections, {this.near = true});
  final String value;
  final int tokenIndex;
  final int corrections;
  final bool near;
  int get rank => (near ? 10 : 0) - corrections;
}

class _RegionHit {
  _RegionHit(this.region, this.corrections);
  final EthiopianRegion region;
  final int corrections;
}
