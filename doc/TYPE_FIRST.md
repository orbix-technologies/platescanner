# Type-first recognition

Ethiopian plates are several **families**. The scanner classifies the family
first, then runs a reader that only knows that family’s geometry and alphabet.

## Families (`PlateFamily`)

| Family | Meaning |
|---|---|
| `classicSingle` | Circled code · Ge’ez · number · Latin stack on one row |
| `classicTwoRow` | Letters/code on top, large serial below |
| `nationalEth` | 2026 national plate (`ETH` / `AAA####`), no region |
| `special` | Police, CD, UN, AU, temporary, daily permit |
| `unknown` | No strong signal — review is forced |

Service category (taxi / private / …) remains `PlateServiceType`.

## Pipeline

1. Confirm plate area on the still.
2. Primary segmentation + whole-area OCR → `TypeFeatures`.
3. `PlateTypeClassifier` → `PlateTypeDecision` (logged as `typeDecision`).
4. `TypedPlateReader.collectBallots` for that family (prep consensus inside).
5. `voteReadings` → review UI.
6. On Done, log `family` and `confirmedFamily` (from the confirmed fields).

Classifier rules (v1, pure Dart): ETH → special → two-row → classic → unknown.
See `lib/src/recognition/plate_type_classifier.dart`.

## Labelling for Phase 3

Seeded fixture labels live in [`test/fixtures/types.json`](../test/fixtures/types.json):

```json
{ "real_c06703": { "family": "classicSingle", "plate": "2-AA-C06703" } }
```

Evaluate:

```bash
dart run tool/type_eval.dart
```

Field sessions write `typeDecision` / `confirmedFamily` into
`cache/et_plate_logs/session_*.json`. Export those into `types.json` (or a
larger labels set) to train **per-family** glyph/CRNN models later. Swap only
the reader behind `TypedPlateReader`; keep `EtPlateReader.scan` unchanged.

## Manual checklist

Same physical plate ×3 for each family: classic single, two-row, ETH national,
one special. Type and canonical string should be stable; unknown / low type
confidence must open review even when `showReview: false`.
