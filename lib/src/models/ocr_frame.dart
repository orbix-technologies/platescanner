/// Axis-aligned box in normalized image coordinates (`0.0`–`1.0`, upright).
class NormalizedRect {
  /// Creates a box from its edges.
  const NormalizedRect(this.left, this.top, this.right, this.bottom);

  /// Left edge.
  final double left;

  /// Top edge.
  final double top;

  /// Right edge.
  final double right;

  /// Bottom edge.
  final double bottom;

  /// Width.
  double get width => right - left;

  /// Height.
  double get height => bottom - top;

  /// Horizontal centre.
  double get centerX => (left + right) / 2;

  /// Vertical centre.
  double get centerY => (top + bottom) / 2;

  /// Whether the centre of [other] lies inside this box.
  bool containsCenterOf(NormalizedRect other) =>
      other.centerX >= left &&
      other.centerX <= right &&
      other.centerY >= top &&
      other.centerY <= bottom;

  /// Whether [other] lies entirely inside this box, allowing it to poke out
  /// by up to [tolerance] (normalized units) on any side.
  bool contains(NormalizedRect other, {double tolerance = 0}) =>
      other.left >= left - tolerance &&
      other.top >= top - tolerance &&
      other.right <= right + tolerance &&
      other.bottom <= bottom + tolerance;

  @override
  bool operator ==(Object other) =>
      other is NormalizedRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  /// Smallest box containing this and [other].
  NormalizedRect union(NormalizedRect other) => NormalizedRect(
        left < other.left ? left : other.left,
        top < other.top ? top : other.top,
        right > other.right ? right : other.right,
        bottom > other.bottom ? bottom : other.bottom,
      );

  /// Parses `{left, top, right, bottom}` from a platform payload.
  factory NormalizedRect.fromMap(Map<Object?, Object?> map) => NormalizedRect(
        (map['left'] as num).toDouble(),
        (map['top'] as num).toDouble(),
        (map['right'] as num).toDouble(),
        (map['bottom'] as num).toDouble(),
      );

  /// `{left, top, right, bottom}`, as [NormalizedRect.fromMap] reads it.
  Map<String, double> toMap() =>
      {'left': left, 'top': top, 'right': right, 'bottom': bottom};

  @override
  String toString() => 'NormalizedRect($left, $top, $right, $bottom)';
}

/// One line of recognised text.
class OcrLine {
  /// Creates an OCR line.
  const OcrLine({required this.text, required this.box, this.confidence});

  /// Raw recognised text.
  final String text;

  /// Line bounds in normalized image coordinates.
  final NormalizedRect box;

  /// Recogniser confidence (`0.0`–`1.0`), when the backend reports one.
  final double? confidence;

  /// Parses a platform payload line.
  factory OcrLine.fromMap(Map<Object?, Object?> map) => OcrLine(
        text: map['text'] as String? ?? '',
        box: NormalizedRect.fromMap(map),
        confidence: (map['confidence'] as num?)?.toDouble(),
      );
}

/// Recognition output for one analysed camera frame.
class OcrFrame {
  /// Creates a frame result.
  const OcrFrame({
    required this.lines,
    required this.timestamp,
    this.codeHint,
    this.id,
  });

  /// The frame's number on the native side, to ask for its picture
  /// (`frameImage`, patrol); null when not given.

  final int? id;

  /// Recognised lines, any order.
  final List<OcrLine> lines;

  /// Service code read by the native second pass on a circled code
  /// (new-format plates), when the main OCR missed it.
  final String? codeHint;

  /// When the frame was analysed.
  final DateTime timestamp;

  /// Parses a platform `onFrame` payload.
  factory OcrFrame.fromMap(Map<Object?, Object?> map) {
    final raw = (map['lines'] as List<Object?>? ?? const []);
    return OcrFrame(
      lines: raw
          .whereType<Map<Object?, Object?>>()
          .map(OcrLine.fromMap)
          .toList(growable: false),
      timestamp: DateTime.now(),
      codeHint: map['codeHint'] as String?,
      id: map['frameId'] as int?,
    );
  }
}
