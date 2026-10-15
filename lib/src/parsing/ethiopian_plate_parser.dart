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

  /// Serial: optional Latin letter + five digits.
  static final serialPattern = RegExp(r'^[A-Z]?\d{5}$');

  static final _splitter = RegExp(r'[^A-Za-z0-9ሀ-፿]+');
  static final _latinLetter = RegExp(r'^[A-Z]$');
  static const _ignored = {'ETHIOPIA', 'ETH', 'ET-', 'ኢትዮጵያ'};

  // Common OCR confusions on plate fonts.
  static const _toDigit = {
    'O': '0', 'Q': '0', 'D': '0', 'U': '0', //
    'I': '1', 'L': '1', 'J': '1', 'T': '1', '|': '1',
    'Z': '2', 'S': '5', 'B': '8', 'G': '6',
  };
  static const _toLetter = {
    '0': 'O', '1': 'I', '2': 'Z', '5': 'S', '8': 'B', '6': 'G', '4': 'A',
  };

  /// Parses [lines] (any order) into a candidate.
  PlateCandidate parse(List<OcrLine> lines) {
    final sorted = [...lines]..sort((a, b) {
        final dy = a.box.centerY - b.box.centerY;
        if (dy.abs() > 0.02) return dy.sign.toInt();
        return a.box.left.compareTo(b.box.left);
      });

    final tokens = <_Token>[];
    for (var i = 0; i < sorted.length; i++) {
      for (final part in sorted[i].text.split(_splitter)) {
        if (part.isEmpty) continue;
        final upper = part.toUpperCase();
        if (_ignored.contains(upper)) continue;
        tokens.add(_Token(upper, i, tokens.length));
      }
    }

    final rawText = sorted.map((l) => l.text).join('\n');
    final serialHit = _findSerial(tokens);
    final used = <int>{...?serialHit?.tokenIndexes};

    var code = serialHit?.mergedCode;
    var corrections = serialHit?.corrections ?? 0;
    if (code == null) {
      final codeHit = _findCode(tokens, used, serialHit);
      if (codeHit != null) {
        code = codeHit.value;
        corrections += codeHit.corrections;
        used.add(codeHit.tokenIndex);
      }
    }

    String? regionCode;
    final regionHit = _findRegion(tokens, used);
    if (regionHit != null) {
      regionCode = regionHit.region.code;
      corrections += regionHit.corrections;
    } else {
      regionCode = EthiopianRegion.findAmharic(rawText)?.code;
    }

    final serial = serialHit?.value;
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
    if (serial == null || !serialPattern.hasMatch(serial)) {
      issues.add(PlateIssue.missingSerial);
    }
    return issues;
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
    if (s.length < 5 || s.length > 7) return null;

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
      return (buf.toString(), fixes);
    }

    final tail = digits(s.substring(s.length - 5));
    if (tail == null) return null;
    // Too many guessed digits — more likely a word than a serial.
    if (tail.$2 > 2) return null;
    final head = s.substring(0, s.length - 5);
    final joined = indexes.length > 1 ? 1 : 0;

    if (head.isEmpty) {
      return _SerialHit(tail.$1, indexes, tail.$2, null, 10 - tail.$2 - joined);
    }
    if (head.length == 1) {
      if (_latinLetter.hasMatch(head)) {
        return _SerialHit(
            '$head${tail.$1}', indexes, tail.$2, null, 12 - tail.$2 - joined);
      }
      // Single-row plate where the code box merged into the serial.
      if (PlateServiceType.isKnown(head) && int.tryParse(head) != null) {
        return _SerialHit(tail.$1, indexes, tail.$2, head, 9 - tail.$2);
      }
      return null;
    }
    if (head.length == 2) {
      final c = head[0];
      final letter = head[1];
      if (PlateServiceType.isKnown(c) &&
          int.tryParse(c) != null &&
          _latinLetter.hasMatch(letter)) {
        return _SerialHit('$letter${tail.$1}', indexes, tail.$2, c, 9 - tail.$2);
      }
    }
    return null;
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
      final amharic = EthiopianRegion.findAmharic(t.text);
      if (amharic != null) return _RegionHit(amharic, 0);
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
    this.score,
  );
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
