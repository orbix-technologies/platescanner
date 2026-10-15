# Ethiopian Plate Reader

Embeddable Flutter package that reads Ethiopian vehicle licence plates from the
live camera, on-device, and returns a validated `PlateRecord`.

Structure mirrors [`ar_measurement`](https://github.com/seyoumt/orbix_ar):
preflight → controller → view → record, with optional SQLite persistence.

- **[Host integration](doc/HOST_INTEGRATION.md)** — API rules, Android/iOS setup
- **[Supported toolchain](doc/SUPPORTED_TOOLCHAIN.md)** — pinned versions
- **[Recognition model decision](doc/MODEL_DECISION.md)** — why ML Kit / Vision now, custom model next
- **[Plate format](doc/PLATE_FORMAT.md)** — fields, regions, open questions

## Capture loop

1. **Scan** — fit the plate in the guide box
2. **Read** — live reading (code · region · serial) appears
3. **Lock** — auto-locks after 4 identical valid frames, or tap *Use this reading*
4. **Edit / Rescan** — fix any field or start over
5. **Done** → host receives a `PlateRecord`

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

### Device checklist

- [ ] Preview starts and the guide box appears
- [ ] A plate in frame produces a live reading within 1 s
- [ ] Lock happens only after a stable reading
- [ ] Editing a field re-validates it
- [ ] Done returns a `PlateRecord`; history updates
- [ ] Camera permission denied → message, no crash

## License

MIT — see [LICENSE](LICENSE).
