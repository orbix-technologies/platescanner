import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_family.dart';
import '../parsing/plate_service_type.dart';
import '../segmentation/plate_segmenter.dart';

/// Signals used to pick a [PlateFamily] before reading characters.
class TypeFeatures {
  /// Creates features from the confirmed still / primary segmentation.
  const TypeFeatures({
    required this.aspect,
    this.segmentation,
    this.ocr = const AreaOcr(elements: []),
  });

  /// Plate-area width / height on the still (normalized box aspect).
  final double aspect;

  /// Primary segmentation of the plate crop, if available.
  final PlateSegmentation? segmentation;

  /// Whole-area OCR (colours + text hints).
  final AreaOcr ocr;

  /// Builds features from a normalized plate [area] and optional [seg]/[ocr].
  factory TypeFeatures.from({
    required NormalizedRect area,
    PlateSegmentation? seg,
    AreaOcr ocr = const AreaOcr(elements: []),
  }) {
    final h = area.height <= 0 ? 1.0 : area.height;
    return TypeFeatures(aspect: area.width / h, segmentation: seg, ocr: ocr);
  }
}

/// Result of [PlateTypeClassifier.classify].
class PlateTypeDecision {
  /// Creates a decision.
  const PlateTypeDecision({
    required this.family,
    required this.confidence,
    this.reasons = const [],
  });

  /// Chosen family.
  final PlateFamily family;

  /// Confidence in [family] (`0`–`1`).
  final double confidence;

  /// Human-readable rule hits for logs and eval.
  final List<String> reasons;

  /// True when the UI must not auto-skip review.
  bool get requiresReview =>
      family == PlateFamily.unknown || confidence < 0.55;

  /// JSON for session logs / eval.
  Map<String, Object?> toJson() => {
        'family': family.name,
        'confidence': confidence,
        'reasons': reasons,
      };
}

/// Heuristic v1 type router: ETH → special → two-row → classic → unknown.
class PlateTypeClassifier {
  /// Creates a classifier.
  const PlateTypeClassifier({
    this.parser = const EthiopianPlateParser(),
  });

  /// Used for national serial / region helpers.
  final EthiopianPlateParser parser;

  /// Classifies [features] into a [PlateTypeDecision].
  PlateTypeDecision classify(TypeFeatures features) {
    final reasons = <String>[];
    final seg = features.segmentation;
    final ocr = features.ocr;
    final text = ocr.text;

    // 1) New national ETH plate.
    final nationalHit = _nationalHint(ocr, text, reasons);
    if (nationalHit != null) return nationalHit;

    // 2) Special plates (police / CD / UN / AU / temp / daily).
    final specialHit = _specialHint(seg, ocr, text, reasons);
    if (specialHit != null) return specialHit;

    // 3) Two-row classic.
    if (seg?.twoRow == true) {
      reasons.add('segmentation.twoRow');
      return PlateTypeDecision(
        family: PlateFamily.classicTwoRow,
        confidence: 0.9,
        reasons: List.unmodifiable(reasons),
      );
    }
    if (features.aspect >= 1.4 && features.aspect <= 2.85) {
      reasons.add('aspect=${features.aspect.toStringAsFixed(2)} two-row band');
      // Prefer two-row only when classic single signals are weak.
      final hasCircle = seg?.code != null;
      final longNumber = (seg?.numberChars.length ?? 0) >= 5;
      if (!hasCircle || !longNumber || seg == null) {
        return PlateTypeDecision(
          family: PlateFamily.classicTwoRow,
          confidence: seg == null ? 0.65 : 0.75,
          reasons: List.unmodifiable(reasons),
        );
      }
      reasons.add('aspect two-row-like but circle+number present; defer');
    }

    // 4) Classic single-row.
    if (seg != null && seg.found) {
      final circle = seg.code != null;
      final latin = seg.latinStack.length == 2;
      final digits = seg.numberChars.length;
      if (circle || latin || digits >= 5) {
        if (circle) reasons.add('segmentation.code');
        if (latin) reasons.add('segmentation.latinStack');
        if (digits >= 5) reasons.add('segmentation.numberChars=$digits');
        if (features.aspect >= 2.8) {
          reasons.add('aspect=${features.aspect.toStringAsFixed(2)} single-row');
        }
        final conf = circle && latin
            ? 0.9
            : circle || latin
                ? 0.75
                : 0.6;
        return PlateTypeDecision(
          family: PlateFamily.classicSingle,
          confidence: conf,
          reasons: List.unmodifiable(reasons),
        );
      }
    }

    if (features.aspect >= 2.9) {
      reasons.add('aspect=${features.aspect.toStringAsFixed(2)} classic default');
      return PlateTypeDecision(
        family: PlateFamily.classicSingle,
        confidence: 0.55,
        reasons: List.unmodifiable(reasons),
      );
    }

    reasons.add('no strong family signal');
    return PlateTypeDecision(
      family: PlateFamily.unknown,
      confidence: 0.3,
      reasons: List.unmodifiable(reasons),
    );
  }

  PlateTypeDecision? _nationalHint(
    AreaOcr ocr,
    String text,
    List<String> reasons,
  ) {
    final upper = text.toUpperCase();
    for (final e in ocr.elements) {
      final serial = parser.readNationalSerial(e.text);
      if (serial != null) {
        reasons.add('nationalSerial=$serial');
        if (upper.contains('ETH')) reasons.add('text:ETH');
        return PlateTypeDecision(
          family: PlateFamily.nationalEth,
          confidence: 0.95,
          reasons: List.unmodifiable(reasons),
        );
      }
    }
    // ETH mark without a clear classic circle/region stack.
    if (upper.contains('ETH') &&
        !RegExp(r'\b(AA|ET|OR|AM|AF)\b').hasMatch(upper)) {
      reasons.add('text:ETH without classic region token');
      return PlateTypeDecision(
        family: PlateFamily.nationalEth,
        confidence: 0.7,
        reasons: List.unmodifiable(reasons),
      );
    }
    return null;
  }

  PlateTypeDecision? _specialHint(
    PlateSegmentation? seg,
    AreaOcr ocr,
    String text,
    List<String> reasons,
  ) {
    final word = PlateServiceType.fromAmharic(text);
    if (word != null &&
        word != PlateServiceType.national &&
        const {
          PlateServiceType.police,
          PlateServiceType.temporary,
          PlateServiceType.daily,
          PlateServiceType.unitedNations,
          PlateServiceType.africanUnion,
          PlateServiceType.diplomatic,
        }.contains(word)) {
      reasons.add('amharic:${word.code}');
      return PlateTypeDecision(
        family: PlateFamily.special,
        confidence: 0.9,
        reasons: List.unmodifiable(reasons),
      );
    }

    final paper = ocr.paperColor;
    if (paper != null &&
        paper.length == 3 &&
        PaperColor.isYellow(paper[0], paper[1], paper[2])) {
      reasons.add('paper:yellow');
      return PlateTypeDecision(
        family: PlateFamily.special,
        confidence: 0.85,
        reasons: List.unmodifiable(reasons),
      );
    }

    if (seg != null) {
      if (seg.leftDigits.length >= 2 && seg.code == null) {
        reasons.add('segmentation.leftDigits=${seg.leftDigits.length}');
        return PlateTypeDecision(
          family: PlateFamily.special,
          confidence: 0.85,
          reasons: List.unmodifiable(reasons),
        );
      }
      if (seg.leftWord.isNotEmpty && seg.code == null) {
        reasons.add('segmentation.leftWord');
        return PlateTypeDecision(
          family: PlateFamily.special,
          confidence: 0.8,
          reasons: List.unmodifiable(reasons),
        );
      }
      if (seg.latinSideBySide && seg.code == null && seg.geezStack.isEmpty) {
        reasons.add('segmentation.latinSideBySide AU-like');
        return PlateTypeDecision(
          family: PlateFamily.special,
          confidence: 0.75,
          reasons: List.unmodifiable(reasons),
        );
      }
    }

    for (final c in ocr.regionColumns) {
      if (c.letters == 'UN' || c.letters == 'AU' || c.letters == 'CD') {
        reasons.add('regionColumn:${c.letters}');
        return PlateTypeDecision(
          family: PlateFamily.special,
          confidence: 0.88,
          reasons: List.unmodifiable(reasons),
        );
      }
    }

    final upper = text.toUpperCase();
    if (RegExp(r'\b(UN|AU|CD)\b').hasMatch(upper)) {
      reasons.add('text:specialTag');
      return PlateTypeDecision(
        family: PlateFamily.special,
        confidence: 0.7,
        reasons: List.unmodifiable(reasons),
      );
    }
    return null;
  }
}
