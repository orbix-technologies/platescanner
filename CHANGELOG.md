## Unreleased

- Faster still reads: `PreparedStill` (one file load) and primary early-exit
  when OCR confidence ≥ 0.85 and glyph agrees (skips contrast / padVertical).
- Faster live capture: iOS preview Vision `.fast` (still/crops stay `.accurate`);
  adaptive area lock (2 frames when confidence ≥ 0.75, else `stableFrames`).
- Session logs emit a `timings` event (ms per `confirmArea` stage).

## 0.3.0

- Type-first routing: `PlateFamily` + `PlateTypeClassifier` + `TypedPlateReader`.
- Session logs record `typeDecision` / `confirmedFamily`; fixture labels and
  `tool/type_eval.dart` for per-family accuracy ([doc/TYPE_FIRST.md](doc/TYPE_FIRST.md)).

## 0.2.0

- Hybrid reading: native crop OCR (accuracy) + glyph classifier ballots only
  when mean score ≥ 0.62; three-prep consensus (`voteReadings`).
- Bundled glyph bank harvested from fixtures (163 real crops + synthetics).
- Disagreement forces review (`lowAgreement`); `doc/RELIABILITY.md`.

## 0.1.0

- `PlateReader.checkAvailability()` camera-free preflight.
- `PlateReaderController` (`ScanPhase`), multi-frame stability lock, field editing.
- `PlateScannerView` with default HUD and `overlayBuilder`.
- `EthiopianPlateParser`: single/two-row layouts, letter-prefix serials, OCR confusion fixes, special plates.
- Android: CameraX + ML Kit. iOS: AVFoundation + Vision.
- Optional `SqlitePlateRecordStore` with `findBySerial`.
