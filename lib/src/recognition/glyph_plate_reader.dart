import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_section_reader.dart';
import '../segmentation/plate_segmenter.dart';
import 'glyph_classifier.dart';

/// Reads a segmented plate with [GlyphClassifier] instead of scene OCR.
///
/// Produces the same arrangement / candidate shape as
/// [PlateSectionReader.read], so the controller and review UI stay unchanged.
class GlyphPlateReader {
  /// Creates a reader.
  GlyphPlateReader({
    required this.classifier,
    this.parser = const EthiopianPlateParser(),
  }) : _sections = PlateSectionReader(parser: parser);

  /// Glyph classifier.
  final GlyphClassifier classifier;

  /// Field validator / national serial helpers.
  final EthiopianPlateParser parser;

  final PlateSectionReader _sections;

  /// Atomic character crops (digits, latin letters, code, embassy).
  List<SectionCrop> cropsFor(PlateSegmentation seg, NormalizedRect area) {
    final base = _sections.cropsFor(seg, area);
    final digits = _sections.cropsFor(seg, area, digits: true);
    return [
      ...digits,
      ...base.where((c) =>
          c.role == 'number' ||
          c.role == 'latin' ||
          c.role == 'code' ||
          c.role == 'embassy' ||
          c.role == 'latinWord'),
    ];
  }

  /// Classifies every crop of [seg] on [gray] (boxes normalized to the gray
  /// image / plate area — use area `(0,0)–(1,1)` when [gray] is the plate crop).
  ({
    PlateArrangement arrangement,
    PlateCandidate candidate,
    List<GlyphResult> glyphs,
    List<SectionCrop> crops,
  }) read(
    GrayImage gray,
    PlateSegmentation seg,
    AreaOcr ocr, {
    NormalizedRect area = const NormalizedRect(0, 0, 1, 1),
  }) {
    final crops = cropsFor(seg, area);
    final glyphs = <GlyphResult>[];
    final reads = <List<String?>>[];

    String? digitAt(int i) {
      for (var k = 0; k < crops.length; k++) {
        if (crops[k].role == 'digit' && crops[k].index == i) {
          return reads[k].first;
        }
      }
      return null;
    }

    for (final crop in crops) {
      if (crop.role == 'number') {
        // Filled after digits are classified.
        reads.add([null, null, null]);
        glyphs.add(const GlyphResult(
          label: '?',
          score: 0,
          secondLabel: '?',
          secondScore: 0,
        ));
        continue;
      }
      if (crop.role == 'latinWord' && crop.group.length == 2) {
        final a = classifier.classify(gray, _inGray(crop.group[0], area));
        final b = classifier.classify(gray, _inGray(crop.group[1], area));
        final word = '${a.label}${b.label}';
        reads.add([word, word, word]);
        glyphs.add(a);
        continue;
      }
      final box = _inGray(crop.inArea, area);
      final g = classifier.classify(gray, box);
      glyphs.add(g);
      final label = _roleLabel(crop.role, g);
      // Triple format expected by PlateSectionReader.read (colour/bw/clean).
      reads.add([label, label, label]);
    }

    // Build the whole-number string from per-digit labels.
    final n = seg.numberChars.length;
    if (n > 0) {
      final chars = <String>[];
      for (var i = 0; i < n; i++) {
        final d = digitAt(i);
        if (d == null || d.isEmpty) {
          chars.clear();
          break;
        }
        chars.add(d);
      }
      if (chars.length == n) {
        final serial = chars.join();
        for (var k = 0; k < crops.length; k++) {
          if (crops[k].role == 'number') {
            reads[k] = [serial, serial, serial];
          }
        }
      }
    }

    final result = _sections.read(seg, crops, reads, ocr);
    final mean = glyphs.where((g) => g.score > 0).map((g) => g.score);
    final conf = mean.isEmpty
        ? result.candidate.confidence
        : mean.reduce((a, b) => a + b) / mean.length;
    final candidate = PlateCandidate(
      code: result.candidate.code,
      regionCode: result.candidate.regionCode,
      serial: result.candidate.serial,
      layout: result.candidate.layout,
      rawText: 'glyphs:${glyphs.map((g) => g.label).join()}',
      confidence: (conf * (result.candidate.issues.isEmpty ? 1.0 : 0.5))
          .clamp(0.0, 1.0),
      issues: result.candidate.issues,
      boundingBox: result.candidate.boundingBox,
      embassyCode: result.candidate.embassyCode,
    );
    return (
      arrangement: result.arrangement,
      candidate: candidate,
      glyphs: glyphs,
      crops: crops,
    );
  }

  NormalizedRect _inGray(NormalizedRect inArea, NormalizedRect area) {
    // When gray is the plate crop, inArea is already gray-normalized.
    if (area.left == 0 &&
        area.top == 0 &&
        area.right == 1 &&
        area.bottom == 1) {
      return inArea;
    }
    return NormalizedRect(
      (inArea.left - area.left) / area.width,
      (inArea.top - area.top) / area.height,
      (inArea.right - area.left) / area.width,
      (inArea.bottom - area.top) / area.height,
    );
  }

  String _roleLabel(String role, GlyphResult g) {
    if (role == 'digit' || role == 'code' || role == 'embassy') {
      // Prefer digit interpretation under ambiguity.
      for (final c in g.candidates) {
        if (RegExp(r'^[0-9]$').hasMatch(c)) return c;
      }
      return g.label;
    }
    if (role == 'latin') {
      for (final c in g.candidates) {
        if (RegExp(r'^[A-Z]$').hasMatch(c)) return c;
      }
      // Digit look-alike → letter map used by the section reader too.
      const toLetter = {
        '0': 'O',
        '1': 'I',
        '2': 'Z',
        '5': 'S',
        '8': 'B',
        '6': 'G',
      };
      return toLetter[g.label] ?? g.label;
    }
    return g.label;
  }
}
