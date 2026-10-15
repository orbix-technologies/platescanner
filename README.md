# Ethiopian Plate Reader

Embeddable Flutter package that reads Ethiopian vehicle licence plates from the
live camera, on-device, and returns a validated `PlateRecord`.

Structure mirrors [`ar_measurement`](https://github.com/seyoumt/orbix_ar):
preflight → controller → view → record, with optional SQLite persistence.

- **[Host integration](doc/HOST_INTEGRATION.md)** — API rules, Android/iOS setup
- **[Supported toolchain](doc/SUPPORTED_TOOLCHAIN.md)** — pinned versions
- **[Recognition model decision](doc/MODEL_DECISION.md)** — why ML Kit / Vision now, custom model next
- **[Plate format](doc/PLATE_FORMAT.md)** — fields, regions, open questions

## Capture flow

1. **Detect the plate area** — live OCR inside the guide box finds the serial
   and grows a box over the whole plate (code, region, border). It is drawn
   on the preview; when it holds steady the frame freezes (or tap *Capture*).
2. **Confirm or adjust** — the frozen frame shows the area; drag it or its
   corners, then *Confirm area* (or *Retake*).
3. **Read the characters** — native OCR runs on the confirmed crop only
   (upscaled), returning every character with its box. A second pass reads
   the circled code, which Latin OCR misreads as a letter.
4. **Arrange** — characters are grouped into columns left to right, stacked
   letters top to bottom, as placed on the plate; each group is tagged
   Code / Serial / Region (`1 0123456 A/A`). Review, edit if needed, *Done*.
5. **Latin only** — Ge'ez is ignored. The region comes from its Latin letters
   (AA, TG, AM, ET, OM, …) and is mapped to the region table, which carries
   the Amharic label for display.

## Quick start

```dart
import 'package:et_plate_reader/et_plate_reader.dart';

final availability = await PlateReader.checkAvailability();
if (!availability.isSupported) return; // show availability.message

final controller = PlateReaderController();
final record = await Navigator.of(context).push<PlateRecord>(
  MaterialPageRoute(
    builder: (context) => Scaffold(
      body: PlateScannerView(
        controller: controller,
        onPlateConfirmed: (r) => Navigator.pop(context, r),
        onCancel: () => Navigator.pop(context),
        onError: (e) { /* permission / camera failed */ },
      ),
    ),
  ),
);
controller.dispose();
print(record?.canonical); // 2-AA-A12345
```

## Optional persistence

```dart
import 'package:et_plate_reader/persistence.dart';

final store = SqlitePlateRecordStore();
await store.initialize();
final seenBefore = await store.findBySerial(record.serial, regionCode: record.regionCode);
await store.save(record);
```

## Parser only

`EthiopianPlateParser` is pure Dart and usable without the camera, e.g. on
text from another OCR source:

```dart
final c = const EthiopianPlateParser().parse([
  OcrLine(text: '2 AA A12345', box: NormalizedRect(0, 0, 1, 1)),
]);
c.isValid; // true
```

## Public API

| Import | Contents |
|--------|----------|
| `et_plate_reader.dart` | `PlateReader` / `PlateReaderAvailability`, `PlateScannerView`, `PlateReaderController`, `ScanPhase`, `PlateRecord`, `PlateCandidate`, `EthiopianPlateParser`, `EthiopianRegion`, `PlateServiceType`, `PlateStabilityVoter`, `PlateRecognitionService` |
| `persistence.dart` | `PlateRecordStore`, `SqlitePlateRecordStore` |

Do not import `src/` from host apps.

## Example

```bash
cd example && flutter run
```

Demos: default HUD, custom overlay, SQLite history with duplicate detection.

OCR diagnostics on real photos: drop images into `example/assets/samples/`
and run `flutter run -t lib/ocr_probe.dart`; it logs the detected area, the
characters read, the arrangement and the reading for each.

### Device checklist

- [ ] Preview starts and the guide box appears
- [ ] A plate in frame produces a live reading within 1 s
- [ ] Lock happens only after a stable reading
- [ ] Editing a field re-validates it
- [ ] Done returns a `PlateRecord`; history updates
- [ ] Camera permission denied → message, no crash

## License

MIT — see [LICENSE](LICENSE).
