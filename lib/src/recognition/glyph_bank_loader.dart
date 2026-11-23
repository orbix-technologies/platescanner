import 'package:flutter/services.dart' show rootBundle;

import 'glyph_bank.dart';

/// Loads the packaged bank from `assets/glyphs/bank.json`.
///
/// Falls back to [buildSyntheticPrototypes] when the asset is missing
/// (unit tests, hosts that omit the asset) or fails to load.
///
/// Kept separate from [GlyphBank] so tools can import the bank without
/// compiling against `dart:ui`.
Future<GlyphBank> loadGlyphBankAsset({
  String asset = 'packages/et_plate_reader/assets/glyphs/bank.json',
}) async {
  for (final path in [asset, 'assets/glyphs/bank.json']) {
    try {
      final raw = await rootBundle.loadString(path);
      if (raw.isEmpty) continue;
      return GlyphBank.fromJsonString(raw);
    } catch (_) {
      // Try the next path / synthetic bank.
    }
  }
  return GlyphBank(buildSyntheticPrototypes());
}
