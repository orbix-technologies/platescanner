// Builds assets/glyphs/bank.json from synthetic stencil prototypes plus
// labelled crops harvested from test/fixtures/plates.
//
// Run with Flutter's Dart (not a standalone SDK), from the package root:
//
//   flutter pub get
//   dart run tool/build_glyph_bank.dart
//
// If you see PointerDeviceKind / Offset errors, your `dart` is not Flutter's
// (`which dart` should be …/flutter/bin/dart). Use:
//
//   "$(dirname $(which flutter))/dart" run tool/build_glyph_bank.dart
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/recognition/glyph_bank.dart';
import 'package:et_plate_reader/src/recognition/glyph_classifier.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';

/// Fixture stem → known serial / latin / code (when the file name encodes it).
const fixtureLabels = <String, Map<String, String>>{
  'real_c06703': {'serial': 'C06703', 'latin': 'AA'},
  'angled_c06703_a': {'serial': 'C06703', 'latin': 'AA'},
  'angled_c06703_b': {'serial': 'C06703', 'latin': 'AA'},
  'angled_c06703_c': {'serial': 'C06703', 'latin': 'AA'},
  'bold_tops_c06703_a': {'serial': 'C06703', 'latin': 'AA'},
  'bold_tops_c06703_b': {'serial': 'C06703', 'latin': 'AA'},
  'real_a41601': {'serial': 'A41601', 'latin': 'AA'},
  'real_b88418': {'serial': 'B88418', 'latin': 'AA'},
  'real_70695_edge': {'serial': '70695', 'latin': 'AA'},
  'real_70695_joined_aa': {'serial': '70695', 'latin': 'AA'},
  'real_71462': {'serial': '71462', 'latin': 'AA'},
  'real_94529': {'serial': '94529', 'latin': 'ET'},
  'two_row_04765': {'serial': '04765', 'latin': 'AA'},
  'two_row_a45699': {'serial': 'A45699', 'latin': 'AA'},
  'two_row_a84451': {'serial': 'A84451', 'latin': 'AA'},
  'two_row_b00761': {'serial': 'B00761', 'latin': 'AA'},
  'two_row_51988_et': {'serial': '51988', 'latin': 'ET'},
  'af': {'latin': 'AF'},
  'am': {'latin': 'AM'},
  'dr': {'latin': 'DR'},
  'or': {'latin': 'OR'},
  'et': {'latin': 'ET'},
  'sm': {'latin': 'SM'},
  'gm': {'latin': 'GM'},
  'red5': {'code': '5'},
  'aa_touching_watermark': {'latin': 'AA'},
  'six_beside_aa': {'latin': 'AA'},
  'tilted_aa': {'latin': 'AA'},
  'or_border_sliver': {'latin': 'OR'},
  'stencil_one_hr': {'latin': 'HR'},
  'un': {'latin': 'UN'},
  'au': {'latin': 'AU'},
  'cd': {'latin': 'CD'},
  'police': {'latin': 'AA'},
};

void main() {
  final prototypes = <GlyphPrototype>[...buildSyntheticPrototypes()];
  var harvested = 0;
  for (final e in fixtureLabels.entries) {
    final path = 'test/fixtures/plates/${e.key}.png';
    if (!File(path).existsSync()) continue;
    final gray = plateGraySync(path, const NormalizedRect(0, 0, 1, 1));
    final seg = segmentCaptureSync(path, const NormalizedRect(0, 0, 1, 1));
    if (gray == null || seg == null || !seg.found) {
      stdout.writeln('skip ${e.key}: seg=${seg?.found}');
      continue;
    }
    final serial = e.value['serial'];
    if (serial != null && serial.length == seg.numberChars.length) {
      for (var i = 0; i < serial.length; i++) {
        prototypes.add(GlyphPrototype(
          serial[i],
          GlyphClassifier.extractMask(gray, seg.numberChars[i]),
        ));
        harvested++;
      }
    }
    final latin = e.value['latin'];
    if (latin != null && latin.length == seg.latinStack.length) {
      for (var i = 0; i < latin.length; i++) {
        prototypes.add(GlyphPrototype(
          latin[i],
          GlyphClassifier.extractMask(gray, seg.latinStack[i]),
        ));
        harvested++;
      }
    }
    final code = e.value['code'];
    final codeBox = seg.codeInner ?? seg.code;
    if (code != null && codeBox != null) {
      prototypes.add(GlyphPrototype(
        code,
        GlyphClassifier.extractMask(gray, codeBox),
      ));
      harvested++;
    }
  }

  final kept = [
    for (final p in prototypes)
      if (p.mask.any((v) => v > 0)) p,
  ];

  final bank = GlyphBank(kept);
  final out = File('assets/glyphs/bank.json');
  out.parent.createSync(recursive: true);
  // Compact JSON keeps the asset under ~0.5 MB with synthetics + harvest.
  out.writeAsStringSync(jsonEncode(bank.toJson()));
  stdout.writeln(
    'Wrote ${out.path}: ${kept.length} prototypes '
    '(${bank.labels.length} labels, $harvested harvested from fixtures).',
  );
}
