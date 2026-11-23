## 0.2.0

Production readiness:

- Android release builds: the package ships R8 keep rules (consumer rules) for
  ML Kit and LiteRT. Without them a release build's camera view crashed on
  creation and text recognition could not start.
- Photos of scans that end without a result (retake, cancel, closed) are
  deleted; before, every capture stayed in the app's cache. The confirmed
  scan's photo stays with the host (`PlateRecord.imagePath`).
- A failed read after a retake no longer switches the scanner to the error
  state.
- Session logs (debug builds) keep the newest 500 sessions.

Reading (real scans, SM-A176B and SM-M166P, 2026-11-19 to 2026-11-23):

- New national plate (ETH) read even when its last digits look like stacked
  region letters, when the whole-area OCR reads "ETH" beside it.
- Region letters found inside a shape joined to the plate's border and a
  screw (4-ET-28313).
- Region from the whole-area OCR line across the region letters ("QhtET,")
  when a letter crop reads nothing or a letter misread once.
- Number reads spanning several lines (badge above the plate): the digit line.
- Text-only fallback: a two-row plate's top row gives the region ("hhAA"), and
  a series letter A–E before five digits is kept (C64915).
- AA from two region letters drawn alike; colour judged against the paper;
  region from one letter only one region has there; one-row/two-row and
  circle detection fixes.

## 0.1.0

- `PlateReader.checkAvailability()` camera-free preflight.
- `PlateReaderController` (`ScanPhase`), multi-frame stability lock, field editing.
- `PlateScannerView` with default HUD and `overlayBuilder`.
- `EthiopianPlateParser`: single/two-row layouts, letter-prefix serials, OCR confusion fixes, special plates.
- Android: CameraX + ML Kit. iOS: AVFoundation + Vision.
- Optional `SqlitePlateRecordStore` with `findBySerial`.
