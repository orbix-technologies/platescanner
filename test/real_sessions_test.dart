import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_replay.dart';

/// Regression tests from real scans: OCR recorded on a phone (session logs)
/// replayed through the arranger. `expectedNumber` is what the photographed
/// plate actually says.
void main() {
  final files = Directory('test/fixtures/sessions')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in files) {
    final log = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    final expected = log['expectedNumber'] as String;
    test('${log['session']}: number $expected', () {
      final ocr = areaOcrFromSession(f)!;
      final r = const PlateArranger().arrange(ocr);
      expect(r.arrangement.number.value, expected, reason: 'OCR: ${ocr.text}');
    });
  }
}
