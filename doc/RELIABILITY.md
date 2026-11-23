# Reliable recognition

## Problem

General scene OCR (ML Kit / Vision) is stochastic: the same plate scanned
twice often yields different characters. Ethiopian plates use a tiny fixed
character set, so that is the wrong model class.

## Approach (v0.3 type-first)

1. **Classify family** first (`PlateTypeClassifier`: classic / two-row / ETH /
   special / unknown) — see [TYPE_FIRST.md](TYPE_FIRST.md).
2. **Read with a typed reader** (`TypedPlateReader`) that only uses that
   family’s path (ETH skips classic section crops; unknown forces review).
3. Inside classic/special: crop OCR + glyph ballots when mean score ≥ 0.62,
   three `SegmentPrep` variants, then `voteReadings`.
4. Disagreement, unknown family, or low type confidence → review
   (`requiresReview`).

Scene OCR remains for live framing, colours, and national/special text hints.

## Rebuild the glyph bank

Use **Flutter's** `dart` (the one next to `flutter`), from the package root:

```bash
flutter pub get
dart run tool/build_glyph_bank.dart
```

If you see `PointerDeviceKind` / `Offset` compile errors, `dart` on your
PATH is not Flutter's. Run:

```bash
"$(dirname "$(which flutter)")/dart" run tool/build_glyph_bank.dart
```

Writes `assets/glyphs/bank.json` from synthetic stencil prototypes plus
labelled crops in `test/fixtures/plates/`. Re-run after adding fixtures with
known serials / region letters (see the map in the tool).

**Reading path:** each scan votes native crop OCR (accuracy) plus glyph
ballots only when mean glyph score ≥ 0.62 (so a weak synthetic bank cannot
override a good OCR read).

## Tests

- `test/glyph_classifier_test.dart` — synthetic charset smoke
- `test/reading_consensus_test.dart` — majority / disagreement
- `test/reliability_repeat_test.dart` — same fixture → identical key ×5

## Manual device check

Scan the same plate three times under steady light. The three `canonical`
strings must match. If the review sheet shows “Readings disagreed”, the
passes did not lock — retake closer / steadier.

## Next (not this branch)

Custom detector + CRNN once ≥ 5 000 labelled crops exist — see
[MODEL_DECISION.md](MODEL_DECISION.md).
