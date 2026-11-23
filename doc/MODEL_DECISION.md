# Recognition model decision

## Now (0.3.0): type-first routing + hybrid OCR/glyph; OCR for live framing

Plate family is classified before reading ([TYPE_FIRST.md](TYPE_FIRST.md)).
Character crops still use native OCR with optional glyph ballots.

## Was (0.2.0): glyph bank + consensus; OCR for live framing only

| | Android | iOS |
|---|---|---|
| Camera | CameraX Preview + ImageAnalysis (keep-latest), shared ViewPort | AVCaptureSession, aspect-fill preview |
| Live area | ML Kit Latin text recognition (bundled) | Vision `VNRecognizeTextRequest` (`.fast` live; `.accurate` still) |
| Characters | Dart `GlyphClassifier` over segmented ink masks | Same (pure Dart) |
| Stability | 3× `SegmentPrep` consensus on one still (`voteReadings`) | Same |

Decisions live in Dart: `EthiopianPlateParser`, `GlyphPlateReader`,
`voteReadings`. See [RELIABILITY.md](RELIABILITY.md).

**Limitation:** Ge'ez is still not read (spelled from Latin). Synthetic +
fixture prototypes beat scene OCR on repeatability; a trained CRNN remains
the accuracy ceiling.

## Next: custom detector + CRNN

1. Collect ≥ 5,000 labelled plate crops (regions, day/night, both layouts).
2. Train a plate detector and a CRNN on digits + Latin + Ge'ez region set.
3. Ship as LiteRT (Android) / Core ML (iOS) behind the same channel contract
   (`onFrame {lines}`), so Dart code does not change.
