// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'plate_record.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PlateLocation _$PlateLocationFromJson(Map<String, dynamic> json) =>
    PlateLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$PlateLocationToJson(PlateLocation instance) =>
    <String, dynamic>{
      'latitude': instance.latitude,
      'longitude': instance.longitude,
      'accuracyMeters': instance.accuracyMeters,
    };

PlateRecord _$PlateRecordFromJson(Map<String, dynamic> json) => PlateRecord(
      id: json['id'] as String,
      code: json['code'] as String,
      regionCode: json['regionCode'] as String?,
      serial: json['serial'] as String,
      layout: $enumDecode(_$PlateLayoutEnumMap, json['layout']),
      rawText: json['rawText'] as String,
      confidence: (json['confidence'] as num).toDouble(),
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      editedByUser: json['editedByUser'] as bool? ?? false,
      imagePath: json['imagePath'] as String?,
      location: json['location'] == null
          ? null
          : PlateLocation.fromJson(json['location'] as Map<String, dynamic>),
      description: json['description'] as String?,
      status: json['status'] as String? ?? 'confirmed',
      plateArea: _rectFromJson(json['plateArea'] as Map<String, dynamic>?),
      sectionAreas: json['sectionAreas'] == null
          ? const {}
          : _areasFromJson(json['sectionAreas'] as Map<String, dynamic>?),
    );

Map<String, dynamic> _$PlateRecordToJson(PlateRecord instance) =>
    <String, dynamic>{
      'id': instance.id,
      'code': instance.code,
      'regionCode': instance.regionCode,
      'serial': instance.serial,
      'layout': _$PlateLayoutEnumMap[instance.layout]!,
      'rawText': instance.rawText,
      'confidence': instance.confidence,
      'capturedAt': instance.capturedAt.toIso8601String(),
      'editedByUser': instance.editedByUser,
      'imagePath': instance.imagePath,
      'location': instance.location?.toJson(),
      'description': instance.description,
      'status': instance.status,
      'plateArea': _rectToJson(instance.plateArea),
      'sectionAreas': _areasToJson(instance.sectionAreas),
    };

const _$PlateLayoutEnumMap = {
  PlateLayout.singleRow: 'singleRow',
  PlateLayout.twoRow: 'twoRow',
  PlateLayout.unknown: 'unknown',
};
