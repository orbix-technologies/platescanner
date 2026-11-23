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
    this.earlyExitMinConfidence = 0.85,
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

  /// Primary OCR must meet this confidence to skip extra prep passes.
  final double earlyExitMinConfidence;

  final PlateArranger _arranger;
  final PlateSectionReader _sections;
  final GlyphPlateReader _glyph;

  /// Whether primary OCR (and optional glyph) are strong enough to skip
  /// contrast / padVertical consensus passes.
  static bool shouldEarlyExit({
    required PlateCandidate ocr,
    PlateCandidate? glyph,
    double minConfidence = 0.85,
  }) {
    final serial = ocr.serial;
    if (serial == null || serial.isEmpty) return false;
    if (ocr.confidence < minConfidence) return false;
    if (!_mildIssues(ocr.issues)) return false;
    if (glyph == null) return true;
    return glyph.key == ocr.key;
  }

  /// [missingCode] alone is mild (circle often hard); other issues block.
  static bool _mildIssues(List<PlateIssue> issues) {
    if (issues.isEmpty) return true;
    return issues.length == 1 && issues.first == PlateIssue.missingCode;
  }

  /// Collects consensus ballots for [family] on the still at [path].
  ///
  /// Pass [still] to avoid re-reading the JPEG for each prep. Pass
  /// [primarySeg] when the controller already segmented primary for type
  /// classification so that pass is not repeated.
  Future<List<TypedReadPass>> collectBallots({
    required PlateFamily family,
    required String path,
    required NormalizedRect area,
    required AreaOcr ocr,
    required Future<List<List<String?>>> Function(List<CropSpec> crops)
        readCrops,
    PreparedStill? still,
    PlateSegmentation? primarySeg,
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
          still: still,
          primarySeg: primarySeg,
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
    PreparedStill? still,
    PlateSegmentation? primarySeg,
    void Function(String name, [Map<String, Object?> data])? log,
    void Function(PlateSegmentation seg)? onPrimarySegmentation,
    required bool includeGlyph,
  }) async {
    final out = <TypedReadPass>[];

    for (final prep in SegmentPrep.values) {
      PlateSegmentation? seg;
      if (prep == SegmentPrep.primary && primarySeg != null) {
        seg = primarySeg;
      } else {
        try {
          seg = await segmentCapture(path, area, prep: prep, still: still);
        } catch (e) {
          log?.call('segmentationError', {'error': '$e', 'prep': prep.name});
        }
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
      final ocrBallot = TypedReadPass(
        candidate: ocrPass.candidate,
        arrangement: ocrPass.arrangement,
        source: 'ocr:${prep.name}',
      );
      out.add(ocrBallot);

      TypedReadPass? glyphBallot;
      if (includeGlyph) {
        final gray = plateGraySync(path, area, prep: prep, still: still);
        if (gray != null) {
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
            glyphBallot = TypedReadPass(
              candidate: glyphPass.candidate,
              arrangement: glyphPass.arrangement,
              source: 'glyph:${prep.name}',
            );
            out.add(glyphBallot);
          }
        }
      }

      if (prep == SegmentPrep.primary) {
        if (shouldEarlyExit(
          ocr: ocrBallot.candidate,
          glyph: glyphBallot?.candidate,
          minConfidence: earlyExitMinConfidence,
        )) {
          log?.call('typedReader', {
            'earlyExit': true,
            'prep': prep.name,
            'ocrKey': ocrBallot.candidate.key,
            'glyphKey': glyphBallot?.candidate.key,
            'confidence': ocrBallot.candidate.confidence,
          });
          return out;
        }
        log?.call('typedReader', {
          'earlyExit': false,
          'prep': prep.name,
          'ocrKey': ocrBallot.candidate.key,
          'confidence': ocrBallot.candidate.confidence,
        });
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
