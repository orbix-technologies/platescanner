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
