import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_arranger.dart';
import '../parsing/plate_family.dart';
import '../parsing/plate_section_reader.dart';
import '../segmentation/plate_segmenter.dart';
import '../segmentation/segment_capture.dart';
import 'glyph_classifier.dart';
import 'glyph_plate_reader.dart';
import 'plate_recognition_service.dart';

/// One recognition ballot from a typed reader pass.
class TypedReadPass {
  /// Creates a pass result.
  const TypedReadPass({
    required this.candidate,
    required this.arrangement,
    required this.source,
  });

  /// Reading for consensus.
  final PlateCandidate candidate;

  /// Section layout for the review UI.
  final PlateArrangement arrangement;

  /// Origin label (`ocr:primary`, `national`, `glyph:contrast`, …).
  final String source;
}

/// Family-specific reading that delegates to existing segment / OCR / glyph
/// code. The controller classifies first, then calls [collectBallots].
class TypedPlateReader {
  /// Creates a reader.
  TypedPlateReader({
    EthiopianPlateParser parser = const EthiopianPlateParser(),
    GlyphClassifier? glyphClassifier,
    this.minGlyphMeanScore = 0.62,
  })  : parser = parser,
        _arranger = PlateArranger(parser: parser),
        _sections = PlateSectionReader(parser: parser),
        _glyph = GlyphPlateReader(
          classifier: glyphClassifier ?? GlyphClassifier.synthetic(),
          parser: parser,
        );

  /// Field parser / national serial helpers.
  final EthiopianPlateParser parser;

  /// Glyph ballots below this mean score are dropped.
  final double minGlyphMeanScore;

  final PlateArranger _arranger;
  final PlateSectionReader _sections;
  final GlyphPlateReader _glyph;

  /// Collects consensus ballots for [family] on the still at [path].
  Future<List<TypedReadPass>> collectBallots({
    required PlateFamily family,
    required String path,
    required NormalizedRect area,
    required AreaOcr ocr,
    required Future<List<List<String?>>> Function(List<CropSpec> crops)
        readCrops,
    void Function(String name, [Map<String, Object?> data])? log,
    void Function(PlateSegmentation seg)? onPrimarySegmentation,
  }) async {
    switch (family) {
      case PlateFamily.nationalEth:
        return _national(ocr, log: log);
      case PlateFamily.unknown:
        final a = _arranger.arrange(ocr);
        return [
          TypedReadPass(
            candidate: a.candidate,
            arrangement: a.arrangement,
            source: 'arrange:unknown',
          ),
        ];
      case PlateFamily.classicSingle:
      case PlateFamily.classicTwoRow:
      case PlateFamily.special:
        return _segmentedFamily(
          path: path,
          area: area,
          ocr: ocr,
          readCrops: readCrops,
          log: log,
          onPrimarySegmentation: onPrimarySegmentation,
          // Special plates still use section crops; section reader applies
          // CD/UN/AU/police rules from layout + colour.
          includeGlyph: family != PlateFamily.special,
        );
    }
  }

  List<TypedReadPass> _national(
    AreaOcr ocr, {
    void Function(String name, [Map<String, Object?> data])? log,
  }) {
    final hit = _arranger.nationalFromOcr(ocr);
    if (hit != null) {
      log?.call('typedReader', {'family': 'nationalEth', 'via': 'nationalFromOcr'});
      return [
        TypedReadPass(
          candidate: hit.candidate,
          arrangement: hit.arrangement,
          source: 'national',
        ),
      ];
    }
    // Fall back to whole-area arrange (may still recover AAA####).
    final a = _arranger.arrange(ocr);
    log?.call('typedReader', {'family': 'nationalEth', 'via': 'arrange'});
    return [
      TypedReadPass(
        candidate: a.candidate,
        arrangement: a.arrangement,
        source: 'arrange:national',
      ),
    ];
  }

  Future<List<TypedReadPass>> _segmentedFamily({
    required String path,
    required NormalizedRect area,
    required AreaOcr ocr,
    required Future<List<List<String?>>> Function(List<CropSpec> crops)
        readCrops,
    void Function(String name, [Map<String, Object?> data])? log,
    void Function(PlateSegmentation seg)? onPrimarySegmentation,
    required bool includeGlyph,
  }) async {
    final out = <TypedReadPass>[];
    for (final prep in SegmentPrep.values) {
      PlateSegmentation? seg;
      try {
        seg = await segmentCapture(path, area, prep: prep);
      } catch (e) {
        log?.call('segmentationError', {'error': '$e', 'prep': prep.name});
      }
      if (prep == SegmentPrep.primary && seg != null) {
        onPrimarySegmentation?.call(seg);
        log?.call('segmentation', {'prep': prep.name, 'found': seg.found});
      }
      if (seg == null || !seg.found) {
        final fallback = _arranger.arrange(ocr);
        out.add(TypedReadPass(
          candidate: fallback.candidate,
          arrangement: fallback.arrangement,
          source: 'arrange:${prep.name}',
        ));
        continue;
      }

      final ocrPass = await _readWithOcrCrops(path, area, seg, ocr, readCrops);
      out.add(TypedReadPass(
        candidate: ocrPass.candidate,
        arrangement: ocrPass.arrangement,
        source: 'ocr:${prep.name}',
      ));

      if (!includeGlyph) continue;
      final gray = plateGraySync(path, area, prep: prep);
      if (gray == null) continue;
      final glyphPass = _glyph.read(gray, seg, ocr);
      final scored =
          glyphPass.glyphs.where((g) => g.score > 0).map((g) => g.score);
      final mean = scored.isEmpty
          ? 0.0
          : scored.reduce((a, b) => a + b) / scored.length;
      if (prep == SegmentPrep.primary) {
        log?.call('glyphs', {
          'labels': [for (final g in glyphPass.glyphs) g.label],
          'scores': [for (final g in glyphPass.glyphs) g.score],
          'meanScore': mean,
        });
      }
      if (mean >= minGlyphMeanScore &&
          glyphPass.candidate.serial != null &&
          glyphPass.candidate.serial!.isNotEmpty) {
        out.add(TypedReadPass(
          candidate: glyphPass.candidate,
          arrangement: glyphPass.arrangement,
          source: 'glyph:${prep.name}',
        ));
      }
    }
    return out;
  }

  Future<({PlateArrangement arrangement, PlateCandidate candidate})>
      _readWithOcrCrops(
    String path,
    NormalizedRect area,
    PlateSegmentation seg,
    AreaOcr ocr,
    Future<List<List<String?>>> Function(List<CropSpec> crops) readCrops,
  ) async {
    var crops = _sections.cropsFor(seg, area);
    var reads = await readCrops([for (final c in crops) c.spec]);
    var result = _sections.read(seg, crops, reads, ocr);
    if (result.arrangement.number.value.isEmpty) {
      final digits = _sections.cropsFor(seg, area, digits: true);
      final more = await readCrops([for (final c in digits) c.spec]);
      crops = [...crops, ...digits];
      reads = [...reads, ...more];
      result = _sections.read(seg, crops, reads, ocr);
    }
    return result;
  }
}
