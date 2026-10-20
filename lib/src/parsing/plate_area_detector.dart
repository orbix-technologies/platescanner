import '../models/ocr_frame.dart';

/// Step 1: finds the area of a frame that holds the plate.
///
/// Anchors on the line carrying the serial (a run of five or more digit-like
/// characters, or the new national plate's three letters and four digits),
/// then grows a box over everything printed on the same band —
/// the code on the left, stacked region letters on the right — plus margin
/// for the plate border. Pure Dart; tuned so the user rarely has to adjust.
class PlateAreaDetector {
  /// Creates a detector.
  const PlateAreaDetector();

  static final _serialLike = RegExp(r'[0-9OQDISBZG]{5,}');
  static final _digit = RegExp(r'[0-9]');

  /// The new national number: three letters and four digits (`ABC1234`).
  /// Its notched 0 is read as G, O, D, Q or C, so the digits may come out
  /// as no digit at all ("AAAGGOO").
  static final _nationalLike = RegExp(r'^[A-Z]{2}[A-Z0-9][0-9OQDGC]{3,5}$');

  /// Plate area in normalized frame coordinates, or `null` if none.
  NormalizedRect? detect(List<OcrLine> lines) => detectDetailed(lines)?.area;

  /// [detect], and whether the anchor is a new national number (`ABC1234`).
  ///
  /// That plate is framed from its number line alone: the ኢት / ETH block
  /// sits left of it, and nothing is printed right of it.
  ({NormalizedRect area, bool national})? detectDetailed(List<OcrLine> lines) {
    OcrLine? anchor;
    var national = false;
    for (final l in lines) {
      final text = l.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final run = _serialLike.firstMatch(text)?.group(0);
      final serial = run != null && _digit.allMatches(run).length >= 4;
      final newPlate = _nationalLike.hasMatch(text);
      if (!serial && !newPlate) continue;
      // The new national number's pattern is specific: it wins over a
      // plain digit run elsewhere in view (another plate, page text).
      final isNational = newPlate && !serial;
      if (anchor == null ||
          (isNational && !national) ||
          (isNational == national && l.box.height > anchor.box.height)) {
        anchor = l;
        national = isNational;
      }
    }
    if (anchor == null) return null;

    final a = anchor.box;
    final h = a.height;
    if (national) {
      // Sideways in units of the line's width: frames aren't square, so a
      // height-based margin is too narrow across. The ኢት / ETH block takes
      // about two of the seven characters' width.
      return (
        area: NormalizedRect(
          _clamp(a.left - 0.32 * a.width),
          _clamp(a.top - 0.3 * h),
          _clamp(a.right + 0.06 * a.width),
          _clamp(a.bottom + 0.3 * h),
        ),
        national: true,
      );
    }
    final bandTop = a.top - 0.6 * h;
    final bandBottom = a.bottom + 0.6 * h;
    var area = a;
    for (final l in lines) {
      if (identical(l, anchor)) continue;
      final b = l.box;
      final inBand = b.centerY >= bandTop && b.centerY <= bandBottom;
      final near = b.right >= a.left - 3 * h && b.left <= a.right + 2 * h;
      if (inBand && near) area = area.union(b);
    }

    // Margin for the plate border and a circled code OCR may have missed.
    return (
      area: NormalizedRect(
        _clamp(area.left - 0.9 * h),
        _clamp(area.top - 0.35 * h),
        _clamp(area.right + 0.5 * h),
        _clamp(area.bottom + 0.35 * h),
      ),
      national: false,
    );
  }

  static double _clamp(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
}

/// Decides when a detected area has held still long enough to capture.
class PlateAreaTracker {
  /// Creates a tracker needing [stableFrames] consecutive overlapping areas.
  PlateAreaTracker({this.stableFrames = 3, this.minOverlap = 0.7});

  /// Consecutive overlapping detections needed.
  final int stableFrames;

  /// Minimum intersection-over-union between consecutive detections.
  final double minOverlap;

  NormalizedRect? _last;
  int _streak = 0;

  /// Progress towards a stable area (`0.0`–`1.0`).
  double get progress => (_streak / stableFrames).clamp(0.0, 1.0);

  /// Feeds one frame's detection; returns `true` once stable.
  bool add(NormalizedRect? area) {
    final last = _last;
    if (area == null) {
      _streak = 0;
      _last = null;
      return false;
    }
    _streak = last != null && iou(last, area) >= minOverlap ? _streak + 1 : 1;
    _last = area;
    return _streak >= stableFrames;
  }

  /// Clears the run.
  void reset() {
    _streak = 0;
    _last = null;
  }

  /// Intersection over union of two boxes.
  static double iou(NormalizedRect a, NormalizedRect b) {
    final w = (a.right < b.right ? a.right : b.right) -
        (a.left > b.left ? a.left : b.left);
    final h = (a.bottom < b.bottom ? a.bottom : b.bottom) -
        (a.top > b.top ? a.top : b.top);
    if (w <= 0 || h <= 0) return 0;
    final inter = w * h;
    return inter / (a.width * a.height + b.width * b.height - inter);
  }
}
