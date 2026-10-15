import 'ocr_frame.dart';

/// A still camera frame saved for area confirmation.
///
/// The image covers exactly the visible preview, so preview-normalized
/// coordinates (e.g. a detected plate area) map 1:1 onto it.
class CapturedFrame {
  /// Creates a captured frame.
  const CapturedFrame({
    required this.path,
    required this.width,
    required this.height,
  });

  /// JPEG file path.
  final String path;

  /// Pixel width.
  final int width;

  /// Pixel height.
  final int height;

  /// Parses a platform payload.
  factory CapturedFrame.fromMap(Map<Object?, Object?> map) => CapturedFrame(
        path: map['path'] as String,
        width: (map['width'] as num).toInt(),
        height: (map['height'] as num).toInt(),
      );
}

/// One recognised character, with its box in area-normalized coordinates.
class OcrSymbol {
  /// Creates a symbol.
  const OcrSymbol({required this.text, required this.box});

  /// The character (may be more than one code unit).
  final String text;

  /// Bounds inside the plate area (`0.0`–`1.0`).
  final NormalizedRect box;

  /// Parses a platform payload.
  factory OcrSymbol.fromMap(Map<Object?, Object?> map) => OcrSymbol(
        text: map['text'] as String? ?? '',
        box: NormalizedRect.fromMap(map),
      );
}

/// One recognised word / line fragment inside the plate area.
class OcrElement {
  /// Creates an element.
  const OcrElement({
    required this.text,
    required this.box,
    this.confidence,
    this.symbols = const [],
  });

  /// Recognised text.
  final String text;

  /// Bounds inside the plate area (`0.0`–`1.0`).
  final NormalizedRect box;

  /// Recogniser confidence, when reported.
  final double? confidence;

  /// Per-character boxes, when the backend reports them.
  final List<OcrSymbol> symbols;

  /// Parses a platform payload.
  factory OcrElement.fromMap(Map<Object?, Object?> map) => OcrElement(
        text: map['text'] as String? ?? '',
        box: NormalizedRect.fromMap(map),
        confidence: (map['confidence'] as num?)?.toDouble(),
        symbols: (map['symbols'] as List<Object?>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map(OcrSymbol.fromMap)
            .toList(growable: false),
      );
}

/// Character-level OCR of a confirmed plate area.
class AreaOcr {
  /// Creates a result.
  const AreaOcr({required this.elements, this.codeHint});

  /// Recognised elements, any order.
  final List<OcrElement> elements;

  /// Service code read from the circled-code disc, when found.
  final String? codeHint;

  /// Parses a platform payload.
  factory AreaOcr.fromMap(Map<Object?, Object?> map) => AreaOcr(
        elements: (map['elements'] as List<Object?>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map(OcrElement.fromMap)
            .toList(growable: false),
        codeHint: map['codeHint'] as String?,
      );
}

/// What a group of characters on the plate stands for.
enum PlateSegmentRole {
  /// Service code (circled / boxed number, or CD / AU / UN / POLICE).
  code,

  /// Latin region letters (AA, TG, …).
  region,

  /// Serial number.
  serial,

  /// Read but not part of the plate number (ring, "ETH", stray marks).
  ignored,
}

/// A run of characters placed together on the plate.
class PlateSegment {
  /// Creates a segment.
  const PlateSegment({
    required this.text,
    required this.box,
    required this.column,
    required this.row,
    this.role = PlateSegmentRole.ignored,
  });

  /// Characters, as read.
  final String text;

  /// Bounds inside the plate area (`0.0`–`1.0`).
  final NormalizedRect box;

  /// Column index, left to right.
  final int column;

  /// Row inside its column, top to bottom (stacked letters).
  final int row;

  /// Assigned meaning.
  final PlateSegmentRole role;

  /// Copy with a new [role].
  PlateSegment withRole(PlateSegmentRole role) => PlateSegment(
        text: text,
        box: box,
        column: column,
        row: row,
        role: role,
      );

  @override
  String toString() => 'PlateSegment($text, c$column r$row, ${role.name})';
}

/// Characters of a plate arranged the way they are placed on it.
class PlateArrangement {
  /// Creates an arrangement.
  const PlateArrangement(this.columns);

  /// Columns left to right; each column's segments top to bottom.
  final List<List<PlateSegment>> columns;

  /// All segments in reading order.
  List<PlateSegment> get segments => [for (final c in columns) ...c];

  /// Segments with [role], in reading order.
  List<PlateSegment> withRole(PlateSegmentRole role) =>
      segments.where((s) => s.role == role).toList();

  /// Plate as printed: columns separated by spaces, stacked letters by `/`
  /// (e.g. `1 0123456 A/A`). Ignored segments are left out.
  String get layoutText => columns
      .map((c) => c
          .where((s) => s.role != PlateSegmentRole.ignored)
          .map((s) => s.text)
          .join('/'))
      .where((t) => t.isNotEmpty)
      .join(' ');

  @override
  String toString() => 'PlateArrangement($layoutText)';
}
