import 'package:et_plate_reader/src/recognition/glyph_bank.dart';
import 'package:et_plate_reader/src/recognition/glyph_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final clf = GlyphClassifier.synthetic();

  test('synthetic digits classify as themselves', () {
    for (final d in '0123456789'.split('')) {
      final mask = buildSyntheticPrototypes()
          .firstWhere((p) => p.label == d)
          .mask;
      final r = clf.classifyMask(mask);
      expect(r.label, d, reason: 'digit $d');
      expect(r.score, greaterThan(0.85));
    }
  });

  test('synthetic region letters classify as themselves', () {
    for (final l in 'AAORETSM'.split('')) {
      final mask = buildSyntheticPrototypes()
          .firstWhere((p) => p.label == l)
          .mask;
      final r = clf.classifyMask(mask);
      expect(r.label, l, reason: 'letter $l');
    }
  });

  test('bank JSON round-trip', () {
    final bank = GlyphBank(buildSyntheticPrototypes());
    final again = GlyphBank.fromJson(bank.toJson());
    expect(again.prototypes.length, bank.prototypes.length);
    expect(again.labels, bank.labels);
  });
}
