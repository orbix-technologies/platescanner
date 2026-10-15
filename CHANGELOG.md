## 0.1.0

- `PlateReader.checkAvailability()` camera-free preflight.
- `PlateReaderController` (`ScanPhase`), multi-frame stability lock, field editing.
- `PlateScannerView` with default HUD and `overlayBuilder`.
- `EthiopianPlateParser`: single/two-row layouts, letter-prefix serials, OCR confusion fixes, special plates.
- Android: CameraX + ML Kit. iOS: AVFoundation + Vision.
- Optional `SqlitePlateRecordStore` with `findBySerial`.
