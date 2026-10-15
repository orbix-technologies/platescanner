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

/// Section 4 read by the dedicated pass: a column right of the number cut
/// into a top and a bottom half, each read alone as one letter.
class RegionColumn {
  /// Creates a column.
  const RegionColumn({
    required this.letters,
    required this.source,
    required this.box,
    required this.topHalf,
    required this.bottomHalf,
  });

  /// Two letters, top then bottom (e.g. `AM`).
  final String letters;

  /// Where the column was found: `trailing` (characters OCR put after the
  /// number), `zone` (space right of it) or `lastDigit` (the number's last
  /// character, which OCR may have merged from the stacked letters).
  final String source;

  /// Column bounds inside the plate area.
  final NormalizedRect box;

  /// Top letter bounds.
  final NormalizedRect topHalf;

  /// Bottom letter bounds.
  final NormalizedRect bottomHalf;

  /// Parses a platform payload.
  factory RegionColumn.fromMap(Map<Object?, Object?> map) => RegionColumn(
        letters: map['letters'] as String,
        source: map['source'] as String? ?? 'zone',
        box: NormalizedRect.fromMap(map),
        topHalf:
            NormalizedRect.fromMap(map['topHalf'] as Map<Object?, Object?>),
        bottomHalf:
            NormalizedRect.fromMap(map['bottomHalf'] as Map<Object?, Object?>),
      );
}

/// Character-level OCR of a confirmed plate area.
class AreaOcr {
  /// Creates a result.
  const AreaOcr({
    required this.elements,
    this.codeHint,
    this.regionColumns = const [],
    this.debug = const [],
  });

  /// Recognised elements, any order.
  final List<OcrElement> elements;

  /// Service code read from the circled-code disc, when found.
  final String? codeHint;

  /// Columns the stacked-letter pass read, in the order it tried them; the
  /// arranger uses the first whose letters name a region.
  final List<RegionColumn> regionColumns;

  /// What the native section passes tried and read (diagnostics).
  final List<String> debug;

  /// All recognised text, for diagnostics.
  String get text => elements.map((e) => e.text).join(' ');

  /// Parses a platform payload.
  factory AreaOcr.fromMap(Map<Object?, Object?> map) => AreaOcr(
        elements: (map['elements'] as List<Object?>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map(OcrElement.fromMap)
            .toList(growable: false),
        codeHint: map['codeHint'] as String?,
        regionColumns: (map['regionColumns'] as List<Object?>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map(RegionColumn.fromMap)
            .toList(growable: false),
        debug: (map['debug'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

/// The four sections printed on an Ethiopian plate, left to right.
enum PlateSectionKind {
  /// 1 — circled service code.
  code,

  /// 2 — region in Ge'ez, letters stacked vertically.
  geezRegion,

  /// 3 — the number (serial).
  number,

  /// 4 — region in Latin letters, stacked vertically.
  latinRegion,
}

/// One character read on the plate, with its box in area coordinates.
class PlateChar {
  /// Creates a character.
  const PlateChar(this.text, this.box);

  /// The character as read (after confusion fixes for its section).
  final String text;

  /// Bounds inside the plate area (`0.0`–`1.0`).
  final NormalizedRect box;

  @override
  String toString() => text;
}

/// One section of the plate and the characters found in it.
class PlateSection {
  /// Creates a section.
  const PlateSection({
    required this.kind,
    required this.value,
    this.chars = const [],
    this.box,
    this.detected = true,
  });

  /// Which section this is.
  final PlateSectionKind kind;

  /// Section value: code `1`, Ge'ez `XX` when unreadable, number `01906`,
  /// Latin region `AM`. Empty when nothing was found.
  final String value;

  /// Characters in reading order (stacked sections: top to bottom).
  final List<PlateChar> chars;

  /// Section bounds inside the plate area, when located.
  final NormalizedRect? box;

  /// False when the value is a placeholder (Ge'ez `XX`) or empty.
  final bool detected;

  /// Placeholder shown for Ge'ez that could not be read.
  static const geezPlaceholder = 'XX';

  @override
  String toString() => '${kind.name}=$value$chars';
}

/// A plate split into its four sections, as placed on the plate.
class PlateArrangement {
  /// Creates an arrangement.
  const PlateArrangement({
    required this.code,
    required this.geezRegion,
    required this.number,
    required this.latinRegion,
    this.ignored = const [],
  });

  /// Section 1 — circled code.
  final PlateSection code;

  /// Section 2 — Ge'ez region (stacked).
  final PlateSection geezRegion;

  /// Section 3 — number.
  final PlateSection number;

  /// Section 4 — Latin region (stacked).
  final PlateSection latinRegion;

  /// Characters read that belong to no section (marks, security number).
  final List<PlateChar> ignored;

  /// The four sections, left to right.
  List<PlateSection> get sections => [code, geezRegion, number, latinRegion];

  /// Plate as printed, e.g. `1 XX 01906 AM` (`–` for an empty section).
  String get layoutText =>
      sections.map((s) => s.value.isEmpty ? '–' : s.value).join(' ');

  @override
  String toString() => 'PlateArrangement($layoutText)';
}
