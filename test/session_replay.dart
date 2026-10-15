import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';

/// Rebuilds the [AreaOcr] recorded in a session log (`areaOcr` event).
AreaOcr? areaOcrFromSession(File file) {
  final log = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final events = (log['events'] as List).cast<Map<String, Object?>>();
  final e = events.where((e) => e['event'] == 'areaOcr').firstOrNull;
  if (e == null) return null;

  NormalizedRect rect(Object? m) {
    final r = (m as Map).cast<String, Object?>();
    return NormalizedRect(
      (r['left'] as num).toDouble(),
      (r['top'] as num).toDouble(),
      (r['right'] as num).toDouble(),
      (r['bottom'] as num).toDouble(),
    );
  }

  return AreaOcr(
    elements: [
      for (final el in (e['elements'] as List).cast<Map<String, Object?>>())
        OcrElement(
          text: el['text'] as String,
          box: rect(el['box']),
          confidence: (el['confidence'] as num?)?.toDouble(),
          symbols: [
            for (final s
                in (el['symbols'] as List).cast<Map<String, Object?>>())
              OcrSymbol(text: s['text'] as String, box: rect(s['box'])),
          ],
        ),
    ],
    codeHint: e['codeHint'] as String?,
    inkColor:
        (e['inkColor'] as List?)?.cast<num>().map((v) => v.toInt()).toList(),
    regionColumns: [
      for (final c in ((e['regionColumns'] as List?) ?? const [])
          .cast<Map<String, Object?>>())
        // Halves are not logged; the column box stands in for both.
        RegionColumn(
          letters: c['letters'] as String,
          source: c['source'] as String,
          box: rect(c['box']),
          topHalf: rect(c['box']),
          bottomHalf: rect(c['box']),
        ),
    ],
  );
}
