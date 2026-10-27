import 'package:json_annotation/json_annotation.dart';

import '../parsing/ethiopian_region.dart';
import '../parsing/plate_service_type.dart';
import 'ocr_frame.dart';

part 'plate_record.g.dart';

/// Physical arrangement of the plate fields.
enum PlateLayout {
  /// Code, region and serial on one row (cars).
  singleRow,

  /// Code / region over the serial (motorcycles, small plates).
  twoRow,

  /// Could not be determined.
  unknown,
}

/// A validation problem found on a reading.
enum PlateIssue {
  /// No code-box value was found.
  missingCode,

  /// Code found but not a known service code.
  unknownCode,

  /// No region was found.
  missingRegion,

  /// No serial was found.
  missingSerial,
}

/// Optional GPS fix attached by the host.
@JsonSerializable()
class PlateLocation {
  /// Creates a location.
  const PlateLocation({
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
  });

  /// Latitude in degrees.
  final double latitude;

  /// Longitude in degrees.
  final double longitude;

  /// Horizontal accuracy in meters, if known.
  final double? accuracyMeters;

  /// Deserialises from JSON.
  factory PlateLocation.fromJson(Map<String, dynamic> json) =>
      _$PlateLocationFromJson(json);

  /// Serialises to JSON.
  Map<String, dynamic> toJson() => _$PlateLocationToJson(this);
}

/// Live, per-frame reading streamed to the overlay. Not persisted.
class PlateCandidate {
  /// Creates a candidate.
  const PlateCandidate({
    required this.code,
    required this.regionCode,
    required this.serial,
    required this.layout,
    required this.rawText,
    required this.confidence,
    required this.issues,
    this.boundingBox,
  });

  /// Code-box value (`2`, `CD`, …), or `null` when not read.
  final String? code;

  /// Canonical region code (`AA`, `OR`, …), or `null`.
  final String? regionCode;

  /// Serial such as `A12345`, or `null`.
  final String? serial;

  /// Detected layout.
  final PlateLayout layout;

  /// The OCR text the fields were taken from, lines joined with `\n`.
  final String rawText;

  /// Combined confidence (`0.0`–`1.0`).
  final double confidence;

  /// Validation problems; empty when [isValid].
  final List<PlateIssue> issues;

  /// Plate bounds in normalized image coordinates, if known.
  final NormalizedRect? boundingBox;

  /// True when every required field was read and validated.
  bool get isValid => issues.isEmpty;

  /// Region enum for [regionCode].
  EthiopianRegion? get region => EthiopianRegion.fromCode(regionCode);

  /// Service type for [code].
  PlateServiceType? get serviceType => PlateServiceType.fromCode(code);

  /// Stable key used to vote across frames (`2-AA-A12345`).
  String get key => '${code ?? '?'}-${regionCode ?? '?'}-${serial ?? '?'}';

  @override
  String toString() => 'PlateCandidate($key, conf=$confidence, $issues)';
}

/// A confirmed plate reading returned to the host.
@JsonSerializable(explicitToJson: true)
class PlateRecord {
  /// Creates a record.
  const PlateRecord({
    required this.id,
    required this.code,
    required this.regionCode,
    required this.serial,
    required this.layout,
    required this.rawText,
    required this.confidence,
    required this.capturedAt,
    this.editedByUser = false,
    this.imagePath,
    this.location,
    this.description,
    this.status = 'confirmed',
    this.plateArea,
    this.sectionAreas = const {},
  });

  /// Unique id (UUID v4).
  final String id;

  /// Code-box value (`2`, `CD`, …).
  final String code;

  /// Canonical region code (`AA`, `OR`, …), or `null` when not printed.
  final String? regionCode;

  /// Serial such as `A12345`.
  final String serial;

  /// Detected layout.
  final PlateLayout layout;

  /// OCR text the reading came from.
  final String rawText;

  /// Combined confidence at lock time (`0.0`–`1.0`).
  final double confidence;

  /// When the plate was confirmed.
  final DateTime capturedAt;

  /// True when the user changed any field before confirming.
  final bool editedByUser;

  /// Optional saved crop of the plate.
  final String? imagePath;

  /// Optional GPS fix.
  final PlateLocation? location;

  /// Optional host note.
  final String? description;

  /// Host workflow status (`confirmed` by default).
  final String status;

  /// Where the plate is in [imagePath] (normalized), when known.
  @JsonKey(fromJson: _rectFromJson, toJson: _rectToJson)
  final NormalizedRect? plateArea;

  /// Where each section was read in [imagePath] (normalized): `code`,
  /// `geezRegion`, `number`, `latinRegion` — for checking a reading.
  @JsonKey(fromJson: _areasFromJson, toJson: _areasToJson)
  final Map<String, NormalizedRect> sectionAreas;

  /// Region enum for [regionCode].
  EthiopianRegion? get region => EthiopianRegion.fromCode(regionCode);

  /// Service type for [code].
  PlateServiceType? get serviceType => PlateServiceType.fromCode(code);

  /// Compact form, e.g. `2-AA-A12345`.
  String get canonical => [
        if (code.isNotEmpty) code,
        if (regionCode != null) regionCode,
        serial,
      ].join('-');

  /// Copy with selected fields replaced.
  PlateRecord copyWith({
    String? code,
    String? regionCode,
    String? serial,
    bool? editedByUser,
    String? imagePath,
    PlateLocation? location,
    String? description,
    String? status,
    NormalizedRect? plateArea,
    Map<String, NormalizedRect>? sectionAreas,
  }) {
    return PlateRecord(
      id: id,
      code: code ?? this.code,
      regionCode: regionCode ?? this.regionCode,
      serial: serial ?? this.serial,
      layout: layout,
      rawText: rawText,
      confidence: confidence,
      capturedAt: capturedAt,
      editedByUser: editedByUser ?? this.editedByUser,
      imagePath: imagePath ?? this.imagePath,
      location: location ?? this.location,
      description: description ?? this.description,
      status: status ?? this.status,
      plateArea: plateArea ?? this.plateArea,
      sectionAreas: sectionAreas ?? this.sectionAreas,
    );
  }

  /// Deserialises from JSON.
  factory PlateRecord.fromJson(Map<String, dynamic> json) =>
      _$PlateRecordFromJson(json);

  /// Serialises to JSON.
  Map<String, dynamic> toJson() => _$PlateRecordToJson(this);

  @override
  String toString() => 'PlateRecord($canonical)';
}

NormalizedRect? _rectFromJson(Map<String, dynamic>? json) =>
    json == null ? null : NormalizedRect.fromMap(json);

Map<String, double>? _rectToJson(NormalizedRect? r) => r?.toMap();

Map<String, NormalizedRect> _areasFromJson(Map<String, dynamic>? json) => {
      for (final e in (json ?? const {}).entries)
        e.key: NormalizedRect.fromMap(e.value as Map<Object?, Object?>),
    };

Map<String, Map<String, double>> _areasToJson(
        Map<String, NormalizedRect> areas) =>
    {for (final e in areas.entries) e.key: e.value.toMap()};
