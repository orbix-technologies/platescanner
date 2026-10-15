# Recognition model decision

## Now (0.1.0): platform OCR + Dart parser

| | Android | iOS |
|---|---|---|
| Camera | CameraX Preview + ImageAnalysis (keep-latest), shared ViewPort | AVCaptureSession, aspect-fill preview |
| OCR | ML Kit Latin text recognition (bundled) | Vision `VNRecognizeTextRequest` (.accurate) |
| Output | Lines with confidence, normalized to the visible preview | Same |

Decisions live in Dart: `EthiopianPlateParser` (fields, OCR-confusion fixes,
validation) and `PlateStabilityVoter` (multi-frame agreement).

**Limitation:** neither OCR reads Ge'ez. The region is taken from its Latin
code (AA, OR, …). The parser already accepts Amharic labels for when a
recogniser can produce them.

## Next: custom detector + CRNN

1. Collect ≥ 5,000 labelled plate crops (regions, day/night, both layouts).
2. Train a plate detector and a CRNN on digits + Latin + Ge'ez region set.
3. Ship as LiteRT (Android) / Core ML (iOS) behind the same channel contract
   (`onFrame {lines}`), so Dart code does not change.
