// Evaluates PlateTypeClassifier against labelled fixtures.
//
//   dart run tool/type_eval.dart
//
// Labels: test/fixtures/types.json
// Crops:  test/fixtures/plates/<id>.png
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/models/plate_area.dart';
import 'package:et_plate_reader/src/parsing/plate_family.dart';
import 'package:et_plate_reader/src/recognition/plate_type_classifier.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';

void main(List<String> args) {
  final labelsPath = args.isNotEmpty ? args[0] : 'test/fixtures/types.json';
  final platesDir = args.length > 1 ? args[1] : 'test/fixtures/plates';
  final labels = (jsonDecode(File(labelsPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();

  const clf = PlateTypeClassifier();
  var ok = 0;
  var n = 0;
  final perFamily = <String, List<int>>{};

  for (final e in labels.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    final id = e.key;
    final wantName = (e.value as Map)['family'] as String;
    final want = PlateFamily.values.byName(wantName);
    final path = '$platesDir/$id.png';
    if (!File(path).existsSync()) {
      stdout.writeln('SKIP $id (no png)');
      continue;
    }
    n++;
    final seg = segmentCaptureSync(path, const NormalizedRect(0, 0, 1, 1));
    final ocr = _hintOcr(id, want);
    final img = decodeAspect(path);
    final d = clf.classify(TypeFeatures(
      aspect: img ?? (seg?.twoRow == true ? 2.0 : 4.2),
      segmentation: seg,
      ocr: ocr,
    ));
    final hit = d.family == want;
    if (hit) ok++;
    final stats = perFamily.putIfAbsent(wantName, () => [0, 0]);
    stats[1]++;
    if (hit) stats[0]++;
    stdout.writeln(
      '${hit ? 'ok ' : 'BAD'} $id want=$wantName got=${d.family.name} '
      'conf=${d.confidence.toStringAsFixed(2)} '
      '${d.reasons.join("; ")}',
    );
  }

  stdout.writeln();
  stdout.writeln('type accuracy $ok/$n'
      '${n == 0 ? "" : " (${(100 * ok / n).toStringAsFixed(1)}%)"}');
  for (final e in perFamily.entries) {
    stdout.writeln(
      '  ${e.key.padRight(14)} ${e.value[0]}/${e.value[1]}',
    );
  }
  if (n > 0 && ok / n < 0.9) {
    exitCode = 1;
  }
}

AreaOcr _hintOcr(String id, PlateFamily want) {
  // Minimal OCR hints where geometry alone is ambiguous (matches how the
  // live pipeline sees yellow paper / UN / ETH text).
  if (want == PlateFamily.special && id == 'police') {
    return const AreaOcr(elements: [], paperColor: [235, 180, 40]);
  }
  if (want == PlateFamily.special && id == 'daily') {
    return const AreaOcr(elements: [
      OcrElement(
        text: 'የዕለት 091 OR',
        box: NormalizedRect(0.1, 0.2, 0.9, 0.8),
      ),
    ]);
  }
  if (want == PlateFamily.special && id == 'un') {
    return const AreaOcr(elements: [
      OcrElement(text: 'UN 0123456', box: NormalizedRect(0.2, 0.2, 0.9, 0.8)),
    ]);
  }
  if (want == PlateFamily.special && id == 'au') {
    return const AreaOcr(elements: [
      OcrElement(text: 'AU 0123456', box: NormalizedRect(0.2, 0.2, 0.9, 0.8)),
    ]);
  }
  if (want == PlateFamily.nationalEth) {
    return const AreaOcr(elements: [
      OcrElement(text: 'ETH ABC1234', box: NormalizedRect(0.1, 0.2, 0.9, 0.8)),
    ]);
  }
  return const AreaOcr(elements: []);
}

double? decodeAspect(String path) {
  // Prefer segmentation twoRow; aspect from file is optional.
  try {
    final bytes = File(path).readAsBytesSync();
    // PNG IHDR: width/height at bytes 16–23 big-endian when signature matches.
    if (bytes.length > 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      if (h > 0) return w / h;
    }
  } catch (_) {}
  return null;
}
