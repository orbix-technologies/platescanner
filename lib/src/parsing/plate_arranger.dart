import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import 'ethiopian_plate_parser.dart';
import 'ethiopian_region.dart';

/// Steps 4–5: arranges the characters read inside a confirmed plate area the
/// way they are placed on the plate, and assigns code / serial / region.
///
/// * Characters are grouped into words by spacing, then into columns left
///   to right; letters stacked in one column (`A` over `A`) are rows of it.
/// * Ge'ez is dropped. The region comes from its Latin letters only and is
///   mapped to [EthiopianRegion] (which carries the Amharic label).
class PlateArranger {
  /// Creates an arranger.
  const PlateArranger({this.parser = const EthiopianPlateParser()});

  /// Parser used to read and validate fields.
  final EthiopianPlateParser parser;

  static final _latinOrDigit = RegExp(r'[A-Z0-9]');

  /// Small printed marks that are never part of the number.
  static const _marks = {'ETH'};

  /// Code / region text must be at least this fraction of the serial's
  /// glyph height (filters corner marks and the edge security number).
  static const _minGlyphRatio = 0.25;

  /// Arranges [ocr] and returns the layout plus the reading it implies.
  ({PlateArrangement arrangement, PlateCandidate candidate}) arrange(
    AreaOcr ocr,
  ) {
    final words = <_Word>[];
    for (final e in ocr.elements) {
      words.addAll(_words(e));
    }
    final columns = _columns(words);

    // Serial: the tallest token that reads as one.
    _Word? serialWord;
    ({
      String serial,
      String? mergedCode,
      (String, String)? alternative,
      int corrections,
    })? serialRead;
    for (final w in words) {
      final r = parser.readSerial(w.text);
      if (r == null) continue;
      if (serialWord == null || w.glyph > serialWord.glyph) {
        serialWord = w;
        serialRead = r;
      }
    }
    var serial = serialRead?.serial;
    var corrections = serialRead?.corrections ?? 0;
    if (serialWord != null) {
      serialWord.role = PlateSegmentRole.serial;
      // Too small to be printed plate characters: leave them ignored.
      final minGlyph = serialWord.glyph * _minGlyphRatio;
      for (final w in words) {
        if (w.glyph < minGlyph) w.tooSmall = true;
      }
    }

    // Older plates: a single letter just left of a five-digit serial.
    if (serialWord != null && serial != null && serial.length == 5) {
      final prefix = _leftNeighbour(words, serialWord);
      if (prefix != null &&
          prefix.text.length == 1 &&
          RegExp(r'^[A-Z]$').hasMatch(prefix.text)) {
        serial = '${prefix.text}$serial';
        prefix.role = PlateSegmentRole.serial;
      }
    }

    // Code: circled-code pass, else a code token (nearest left of serial).
    String? code = serialRead?.mergedCode;
    final hint = parser.readCode(ocr.codeHint ?? '');
    if (code == null) {
      final token = _codeToken(words, serialWord);
      if (token != null && (token.$2 == 0 || hint == null)) {
        code = token.$1;
        corrections += token.$2;
        token.$3.role = PlateSegmentRole.code;
      } else if (hint != null) {
        code = hint;
        // The ring read as a letter ("D") stands where the code is.
        final ring = serialWord == null ? null : _leftmostSingle(words);
        if (ring != null) {
          ring
            ..role = PlateSegmentRole.code
            ..display = hint;
        } else {
          final at = serialWord?.box ?? const NormalizedRect(0, 0.3, 0.1, 0.7);
          final synthetic = _Word(
            hint,
            NormalizedRect(
                0, at.top, (at.left * 0.5).clamp(0.02, 1.0), at.bottom),
            null,
          )..role = PlateSegmentRole.code;
          words.add(synthetic);
          columns.insert(0, [synthetic]);
        }
      }
    }
    final alt = serialRead?.alternative;
    if (code == null && alt != null) {
      code = alt.$1;
      serial = alt.$2;
    }

    // Region: stacked single letters in one column, else a letter token.
    EthiopianRegion? region;
    for (final col in columns) {
      final singles = col
          .where(
              (w) => w.role == PlateSegmentRole.ignored && w.text.length == 1)
          .toList();
      if (singles.length < 2) continue;
      final r = parser.readRegion(singles.map((w) => w.text).join());
      if (r != null) {
        region = r;
        for (final w in singles) {
          w.role = PlateSegmentRole.region;
        }
        break;
      }
    }
    if (region == null) {
      for (final w in words) {
        if (!w.free || w.text.length < 2) continue;
        final r = parser.readRegion(w.text);
        if (r != null) {
          region = r;
          w.role = PlateSegmentRole.region;
          break;
        }
      }
    }

    final arrangement = PlateArrangement([
      for (var c = 0; c < columns.length; c++)
        [
          for (var r = 0; r < columns[c].length; r++)
            PlateSegment(
              text: columns[c][r].display ?? columns[c][r].text,
              box: columns[c][r].box,
              column: c,
              row: r,
              role: columns[c][r].role,
            ),
        ],
    ]);

    final confidences =
        ocr.elements.map((e) => e.confidence).whereType<double>().toList();
    var confidence = confidences.isEmpty
        ? 0.8
        : confidences.reduce((a, b) => a + b) / confidences.length;
    for (var i = 0; i < corrections; i++) {
      confidence *= 0.95;
    }
    final issues =
        parser.validate(code: code, regionCode: region?.code, serial: serial);

    final candidate = PlateCandidate(
      code: code,
      regionCode: region?.code,
      serial: serial,
      layout: _layout(arrangement),
      rawText: arrangement.layoutText,
      confidence: confidence.clamp(0.0, 1.0),
      issues: issues,
    );
    return (arrangement: arrangement, candidate: candidate);
  }

  /// Splits an element into words: by spacing between character boxes and
  /// by anything that is not a Latin letter or digit (Ge'ez included).
  List<_Word> _words(OcrElement e) {
    final chars = <(String, NormalizedRect)>[];
    if (e.symbols.isNotEmpty) {
      for (final s in e.symbols) {
        chars.add((_normalize(s.text), s.box));
      }
    } else {
      // No per-character boxes: spread the text evenly over the element.
      final text = e.text;
      final step = text.isEmpty ? 0.0 : e.box.width / text.length;
      for (var i = 0; i < text.length; i++) {
        final left = e.box.left + i * step;
        chars.add((
          _normalize(text[i]),
          NormalizedRect(left, e.box.top, left + step, e.box.bottom),
        ));
      }
    }

    final widths = chars
        .where((c) => _latinOrDigit.hasMatch(c.$1))
        .map((c) => c.$2.width)
        .toList();
    final avg =
        widths.isEmpty ? 0.0 : widths.reduce((a, b) => a + b) / widths.length;

    final words = <_Word>[];
    var buf = StringBuffer();
    NormalizedRect? box;
    var glyph = 0.0;
    void flush() {
      final text = buf.toString();
      if (text.isNotEmpty && box != null && !_marks.contains(text)) {
        words.add(_Word(text, box!, e.confidence, glyph: glyph));
      }
      buf = StringBuffer();
      box = null;
      glyph = 0;
    }

    for (final (ch, b) in chars) {
      if (!_latinOrDigit.hasMatch(ch)) {
        flush();
        continue;
      }
      final current = box;
      if (current != null && b.left - current.right > avg * 0.6) flush();
      // A character stacked under the previous one starts a new word.
      if (current != null && b.top >= current.bottom - b.height * 0.2) flush();
      buf.write(ch);
      box = box == null ? b : box!.union(b);
      if (b.height > glyph) glyph = b.height;
    }
    flush();
    return words;
  }

  static String _normalize(String ch) {
    if (ch.isEmpty) return ch;
    final c = ch.codeUnitAt(0);
    // Circled digits ①–⑤ are the code on new-format plates.
    if (c >= 0x2460 && c <= 0x2464) return '${c - 0x245F}';
    return ch.toUpperCase();
  }

  /// Groups words into columns by horizontal overlap; columns left to right,
  /// each column top to bottom.
  List<List<_Word>> _columns(List<_Word> words) {
    final sorted = [...words]..sort((a, b) => a.box.left.compareTo(b.box.left));
    final columns = <List<_Word>>[];
    final bounds = <NormalizedRect>[];
    for (final w in sorted) {
      var placed = false;
      for (var i = 0; i < columns.length; i++) {
        final c = bounds[i];
        final overlap = (w.box.right < c.right ? w.box.right : c.right) -
            (w.box.left > c.left ? w.box.left : c.left);
        final narrow = w.box.width < c.width ? w.box.width : c.width;
        final stackedNotSameRow =
            columns[i].every((o) => !_sameRow(o.box, w.box));
        if (overlap >= narrow * 0.5 && stackedNotSameRow) {
          columns[i].add(w);
          bounds[i] = c.union(w.box);
          placed = true;
          break;
        }
      }
      if (!placed) {
        columns.add([w]);
        bounds.add(w.box);
      }
    }
    for (final c in columns) {
      c.sort((a, b) => a.box.top.compareTo(b.box.top));
    }
    return columns;
  }

  static bool _sameRow(NormalizedRect a, NormalizedRect b) {
    final overlap = (a.bottom < b.bottom ? a.bottom : b.bottom) -
        (a.top > b.top ? a.top : b.top);
    final short = a.height < b.height ? a.height : b.height;
    return overlap > short * 0.5;
  }

  _Word? _leftNeighbour(List<_Word> words, _Word of) {
    _Word? best;
    for (final w in words) {
      if (identical(w, of) || !w.free) continue;
      if (w.box.right > of.box.left + of.box.width * 0.05) continue;
      if (!_sameRow(w.box, of.box)) continue;
      if (of.box.left - w.box.right > of.box.height) continue;
      if (best == null || w.box.right > best.box.right) best = w;
    }
    return best;
  }

  /// (code, corrections, word) for the best code token, preferring the one
  /// nearest to the left of the serial.
  (String, int, _Word)? _codeToken(List<_Word> words, _Word? serial) {
    (String, int, _Word)? best;
    var bestRank = -1e9;
    for (final w in words) {
      if (!w.free) continue;
      final code = parser.readCode(w.text);
      if (code == null) continue;
      final fixes = (w.text == code) ? 0 : 1;
      var rank = -fixes * 10.0;
      if (serial != null) {
        final left = w.box.right <= serial.box.left + serial.box.width * 0.1;
        rank += left ? 5 - (serial.box.left - w.box.right).abs() : 0;
      }
      if (rank > bestRank) {
        bestRank = rank;
        best = (code, fixes, w);
      }
    }
    return best;
  }

  _Word? _leftmostSingle(List<_Word> words) {
    _Word? best;
    for (final w in words) {
      if (!w.free || w.text.length != 1) continue;
      if (best == null || w.box.left < best.box.left) best = w;
    }
    final serial = words.where((w) => w.role == PlateSegmentRole.serial);
    if (best == null || serial.isEmpty) return null;
    return best.box.right <= serial.first.box.left ? best : null;
  }

  PlateLayout _layout(PlateArrangement a) {
    final serial = a.withRole(PlateSegmentRole.serial);
    if (serial.isEmpty) return PlateLayout.unknown;
    final s = serial.first.box;
    final stackedRows = a.segments
        .where((x) =>
            x.role != PlateSegmentRole.ignored &&
            x.role != PlateSegmentRole.serial &&
            !_sameRow(x.box, s) &&
            x.box.right > s.left &&
            x.box.left < s.right)
        .isNotEmpty;
    return stackedRows ? PlateLayout.twoRow : PlateLayout.singleRow;
  }
}

class _Word {
  _Word(this.text, this.box, this.confidence, {double? glyph})
      : glyph = glyph ?? box.height;
  final String text;
  final NormalizedRect box;
  final double? confidence;

  /// Character height. A vertical column of small digits (the security
  /// number on the plate's edge) has a tall box but small glyphs.
  final double glyph;
  PlateSegmentRole role = PlateSegmentRole.ignored;

  /// Text to show instead of [text] (a ring read as "D" shows the code).
  String? display;

  /// Much smaller than the serial; never code or region.
  bool tooSmall = false;

  /// Still free to become code or region.
  bool get free => role == PlateSegmentRole.ignored && !tooSmall;
}
