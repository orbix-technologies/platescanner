import 'dart:math' as math;
import 'dart:typed_data';

import '../models/ocr_frame.dart';
import '../segmentation/plate_segmenter.dart';
import 'glyph_bank.dart';

/// Result of classifying one glyph crop.
class GlyphResult {
  /// Creates a result.
  const GlyphResult({
    required this.label,
    required this.score,
    required this.secondLabel,
    required this.secondScore,
  });

  /// Best matching class.
  final String label;

  /// Cosine similarity to the best centroid / prototype (`0`–`1`).
  final double score;

  /// Runner-up class.
  final String secondLabel;

  /// Runner-up score.
  final double secondScore;

  /// Gap between best and second; low margin ⇒ ambiguous (`0`/`G`, `6`/`9`).
  double get margin => score - secondScore;

  /// True when the top two are close enough that grammar should decide.
  bool get ambiguous => margin < 0.08 && secondScore > 0.35;

  /// Candidates to try when [ambiguous], best first.
  List<String> get candidates => ambiguous && secondLabel != label
      ? [label, secondLabel]
      : [label];
}

/// Deterministic closed-set classifier: ink mask → cosine vs prototype bank.
class GlyphClassifier {
  /// Creates a classifier over [bank].
  GlyphClassifier(this.bank) : _centroids = bank.centroids;

  /// Prototype bank.
  final GlyphBank bank;

  final Map<String, Float32List> _centroids;

  /// Default bank (synthetic charset) for tests and cold start.
  factory GlyphClassifier.synthetic() =>
      GlyphClassifier(GlyphBank(buildSyntheticPrototypes()));

  /// Classifies the ink inside [box] (normalized to [gray]).
  GlyphResult classify(GrayImage gray, NormalizedRect box) {
    final mask = extractMask(gray, box);
    return classifyMask(mask);
  }

  /// Classifies a pre-extracted [mask] of length [glyphLength].
  GlyphResult classifyMask(Float32List mask) {
    var bestLabel = '?';
    var best = -1.0;
    var secondLabel = '?';
    var second = -1.0;
    for (final e in _centroids.entries) {
      final s = _cosine(mask, e.value);
      if (s > best) {
        second = best;
        secondLabel = bestLabel;
        best = s;
        bestLabel = e.key;
      } else if (s > second) {
        second = s;
        secondLabel = e.key;
      }
    }
    // Also score individual prototypes for rare shapes the centroid misses.
    for (final p in bank.prototypes) {
      final s = _cosine(mask, p.mask);
      if (s > best) {
        second = best;
        secondLabel = bestLabel;
        best = s;
        bestLabel = p.label;
      } else if (s > second && p.label != bestLabel) {
        second = s;
        secondLabel = p.label;
      }
    }
    return GlyphResult(
      label: bestLabel,
      score: best.clamp(0.0, 1.0),
      secondLabel: secondLabel,
      secondScore: second.clamp(0.0, 1.0),
    );
  }

  /// Ink mask of [box] on [gray], resized to [glyphWidth]×[glyphHeight].
  static Float32List extractMask(GrayImage gray, NormalizedRect box) {
    final w = gray.width, h = gray.height;
    var x0 = (box.left * w).floor().clamp(0, w - 1);
    var y0 = (box.top * h).floor().clamp(0, h - 1);
    var x1 = (box.right * w).ceil().clamp(x0 + 1, w);
    var y1 = (box.bottom * h).ceil().clamp(y0 + 1, h);
    // Tighten to ink bounding box inside the proposed cell.
    var minX = x1, minY = y1, maxX = x0, maxY = y0;
    var inkCount = 0;
    final thresh = _otsu(gray, x0, y0, x1, y1);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        if (gray.pixels[y * w + x] < thresh) {
          inkCount++;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (inkCount > 4) {
      x0 = minX;
      y0 = minY;
      x1 = maxX + 1;
      y1 = maxY + 1;
    }
    final bw = x1 - x0, bh = y1 - y0;
    final out = Float32List(glyphLength);
    if (bw <= 0 || bh <= 0) return out;
    // Letterbox into glyph canvas preserving aspect.
    final scale = math.min(glyphWidth / bw, glyphHeight / bh);
    final dw = math.max(1, (bw * scale).round());
    final dh = math.max(1, (bh * scale).round());
    final ox = (glyphWidth - dw) ~/ 2;
    final oy = (glyphHeight - dh) ~/ 2;
    for (var gy = 0; gy < dh; gy++) {
      final sy = y0 + (gy * bh / dh).floor().clamp(0, bh - 1);
      for (var gx = 0; gx < dw; gx++) {
        final sx = x0 + (gx * bw / dw).floor().clamp(0, bw - 1);
        final dark = gray.pixels[sy * w + sx] < thresh ? 1.0 : 0.0;
        out[(oy + gy) * glyphWidth + (ox + gx)] = dark;
      }
    }
    return out;
  }

  static int _otsu(GrayImage g, int x0, int y0, int x1, int y1) {
    final hist = List<int>.filled(256, 0);
    var total = 0;
    final w = g.width;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        hist[g.pixels[y * w + x]]++;
        total++;
      }
    }
    if (total == 0) return 128;
    var sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += i * hist[i];
    }
    var sumB = 0, wB = 0;
    var best = 0.0;
    var thresh = 128;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final sep = wB * wF * (mB - mF) * (mB - mF);
      if (sep > best) {
        best = sep;
        thresh = t;
      }
    }
    return thresh;
  }

  static double _cosine(Float32List a, Float32List b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }
}
