# Ethiopian Plate Reader

A Flutter package that reads Ethiopian vehicle licence plates with the phone
camera, on the device (no network), and returns the plate's parts: code,
region, number and category.

One call opens a ready-made scanner. The user points the camera at the
plate and takes the photo (or it captures by itself), checks the plate
number, edits it if needed, and taps **Done**.

```dart
final result = await EtPlateReader.scan(context);
print(result?.plate); // 2-AA-B05475
```

**Contents:** [Supported plates](#supported-plates) ·
[1. Add the package](#1-add-the-package) ·
[2. Platform setup](#2-platform-setup) · [3. Scan](#3-scan) ·
[4. Use the result](#4-use-the-result) ·
[5. Customise](#5-customise-optional) ·
[Troubleshooting](#troubleshooting) · [More](#more)

## Supported plates

| Plate | Example | `code` | `regionCode` | `serial` |
|---|---|---|---|---|
| Codes 1–5 (taxi, private, commercial, government, civic) | ② ኢት 0123456 ET | `2` | `ET` | `0123456` |
| With a series letter | ② አአ B05475 AA | `2` | `AA` | `B05475` |
| Old two-row plates | ③ አአ AA / 04765 | `3` | `AA` | `04765` |
| Diplomatic | 06 · 0123 CD | `CD` | — | `0123` |
| Police | ፖሊስ · 012345 AA | `POLICE` | `AA` | `012345` |
| Temporary | ተላላፊ · 012345 ET | `TEMP` | `ET` | `012345` |
| UN / AU | የተመ · 0123456 UN | `UN` / `AU` | — | `0123456` |
| New national plate (2026) | ኢት ETH · AAA0000 | `ETH` | — | `AAA0000` |

Regions: ET, AA, AF, AM, BG, DR, GM, HR, OR, SM (and TG, SD, SP, SW, not yet
verified). See [doc/PLATE_FORMAT.md](doc/PLATE_FORMAT.md).

## Requirements

- Flutter ≥ 3.24, Dart ≥ 3.5
- Android: `minSdk` 24; Android Gradle plugin 8.x or 9.x
- iOS 15.0+
- A real device; emulators have no usable camera for OCR

Android has been tested on devices; the iOS side is implemented but has had
less testing.

## 1. Add the package

The package isn't on pub.dev. Add it to the app's `pubspec.yaml` from GitHub:

```yaml
dependencies:
  et_plate_reader:
    git:
      url: https://github.com/orbix-technologies/platescanner.git
      ref: main
```

or, while developing both side by side, from a local folder (the path is
relative to the app's `pubspec.yaml`):

```yaml
dependencies:
  et_plate_reader:
    path: ../et_plate_reader
```

Then run `flutter pub get`.

The package brings its own camera (CameraX on Android, AVFoundation on iOS)
and OCR (ML Kit text recognition on Android, Vision on iOS). The app does
not need the `camera` or `google_mlkit_text_recognition` packages for it.
If the app already uses `google_mlkit_text_recognition`, both use ML Kit
text recognition 16.0.1 (its 0.15.x releases do), so they don't clash.

## 2. Platform setup

### Android

In `android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        minSdk = 24   // instead of flutter.minSdkVersion
    }
}
```

The package already declares the camera permission. Nothing else is needed:
the ML Kit model is bundled (about 4 MB per ABI), so there's no download on
first use.

### iOS

1. In `ios/Podfile`: `platform :ios, '15.0'`.
2. In `ios/Runner/Info.plist`:

   ```xml
   <key>NSCameraUsageDescription</key>
   <string>The camera is used to read licence plates.</string>
   ```

3. In the `Podfile`'s `post_install` block, enable the camera permission for
   `permission_handler`:

   ```ruby
   post_install do |installer|
     installer.pods_project.targets.each do |target|
       flutter_additional_ios_build_settings(target)
       target.build_configurations.each do |config|
         config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
           '$(inherited)',
           'PERMISSION_CAMERA=1',
         ]
       end
     end
   end
   ```

## 3. Scan

```dart
import 'package:et_plate_reader/et_plate_reader.dart';

Future<void> scanPlate(BuildContext context) async {
  // Optional, camera-free check: hide or disable the scan button on devices
  // that can't read plates.
  final availability = await PlateReader.checkAvailability();
  if (!availability.isSupported) return; // availability.message says why

  final result = await EtPlateReader.scan(context);
  if (result == null) return; // the user closed the scanner

  print(result.plate); // 2-AA-B05475
}
```

`scan()`:

- opens full screen above any bottom navigation (it uses the root
  navigator, so it works with `go_router` and nested navigators);
- asks for camera permission, and if it's denied shows a screen with **Open
  settings** and **Try again**;
- returns the confirmed plate, or `null` when the user closes it.

There's nothing to create, initialise or dispose.

## 4. Use the result

`PlateScanResult`:

| Field | Example | Notes |
|---|---|---|
| `plate` | `2-AA-B05475` | The plate as one string (same as `record.canonical`) |
| `record.code` | `2`, `CD`, `POLICE`, `ETH` | Circled code, or the special-plate type |
| `record.regionCode` | `AA` | `null` on plates without a region |
| `record.serial` | `B05475` | The number |
| `record.serviceType` | `PlateServiceType.private` | `.label` is "Private" |
| `record.region` | `EthiopianRegion.addisAbaba` | `.englishName`, `.amharicLabel` ("አአ") |
| `record.layout` | `PlateLayout.singleRow` | or `twoRow` |
| `record.confidence` | `0.0`–`1.0` | |
| `record.editedByUser` | `true` / `false` | The user corrected the reading |
| `plateImage` | `Uint8List` | JPEG of the plate, e.g. as evidence |
| `photoPath` | file path | The full photo, in the app's cache; copy it to keep it |

**Converting to your own format.** If your backend expects a different
plate string, convert it in your app. For example, region + code + number
(`AA207077`):

```dart
String toCompact(PlateRecord r) {
  // Plates without a circled digit (CD, POLICE, UN, AU, ETH) have no code
  // in this format.
  final code = int.tryParse(r.code) == null ? '' : r.code;
  return '${r.regionCode ?? ''}$code${r.serial}';
}
```

Agree with your backend how to send plates that don't fit such a format:
series letters, diplomatic, police and the new ETH plates.

## 5. Customise (optional)

```dart
final result = await EtPlateReader.scan(
  context,
  options: const PlateScannerOptions(showTorch: false),
  strings: const PlateScannerStrings.en().copyWith(done: 'Use plate'),
  theme: const PlateScannerTheme(accent: Colors.orange),
);
```

### Steps — `PlateScannerOptions`

| Option | Default | Effect |
|---|---|---|
| `showReview` | `true` | Show the plate number for a **Done** tap. When `false`, a valid reading returns at once; one with problems is still shown, so a wrong plate is never returned unseen |
| `allowEdit` | `true` | Show the edit button on the result |
| `confirmArea` | `never` | `always`: let the user drag the plate box before reading; `auto`: only when the box couldn't be fitted to the plate |
| `showTorch` | `true` | Torch button on the camera screen |
| `autoCapture` | `true` | Take the photo by itself once the plate holds still (the shutter is always there) |

### Texts — `PlateScannerStrings`

English and Amharic are built in. The scanner picks Amharic when the app's
locale is `am`, and English otherwise. You can:

- force one: `strings: const PlateScannerStrings.am()`;
- change a few: `const PlateScannerStrings.en().copyWith(retake: 'Try again')`;
- or pass a full `PlateScannerStrings(...)` for any other language.

An app that runs in Amharic needs `flutter_localizations` with
`GlobalMaterialLocalizations.delegate` (Flutter's own widgets require it).

### Look — `PlateScannerTheme`

The scanner follows the app's theme. The **Done** button and highlights use
`colorScheme.primary` / `onPrimary`, the result sheet uses
`colorScheme.surface`, and text uses the app's fonts. The camera screen
stays dark. Override with `PlateScannerTheme(accent: …, onAccent: …)`.

### Your own screen

To place the scanner inside your own layout, use `PlateScannerView` with a
`PlateReaderController` that you create and `dispose()`. It takes the same
`options`, `strings` and `theme`, and calls `onPlateConfirmed` with the
`PlateRecord`. See [doc/HOST_INTEGRATION.md](doc/HOST_INTEGRATION.md).

### Without the camera

`EthiopianPlateParser` is pure Dart. It can validate plate parts from any
source:

```dart
const parser = EthiopianPlateParser();
parser.validate(code: '2', regionCode: 'AA', serial: 'B05475'); // [] = valid
```

### Saving readings

```dart
import 'package:et_plate_reader/persistence.dart';

final store = SqlitePlateRecordStore();
await store.initialize();
await store.save(result.record);
final seen = await store.findBySerial(result.record.serial,
    regionCode: result.record.regionCode);
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Android build: `cannot find symbol … EtPlateReaderPlugin` | Update the package: older versions didn't compile their Kotlin code under Android Gradle plugin 8.x |
| `minSdkVersion … cannot be smaller than 24` | Set `minSdk = 24` (step 2) |
| Install fails: `INSTALL_FAILED_UPDATE_INCOMPATIBLE` or `VERSION_DOWNGRADE` | Another build of the app is installed, signed with a different key or with a higher version code. Uninstall it, or build with a higher `--build-number` |
| Black camera screen | Camera permission denied, or another app is using the camera |
| Plate not detected | Fill most of the frame with the plate, hold steady, use the torch at night, or tap the shutter |

### Scan logs (debug builds)

In debug builds each scan is logged (the photo, plus a JSON of every step)
in the app's cache, under `et_plate_logs/`. Turn this on or off with
`EtPlateReader.scan(context, recordSessions: false)`. To copy the logs from
an Android device:

```bash
adb exec-out run-as <your.app.id> tar c cache/et_plate_logs | tar x
```

## More

- [Host integration](doc/HOST_INTEGRATION.md): `PlateScannerView`, the
  controller, platform details
- [Plate format](doc/PLATE_FORMAT.md): every plate type and how it's read
- [Pipeline](doc/PIPELINE.md): each step from camera to reading
- [Supported toolchain](doc/SUPPORTED_TOOLCHAIN.md)
- [Recognition model decision](doc/MODEL_DECISION.md)

### Example app

```bash
cd example && flutter run
```

It shows `EtPlateReader.scan` with the defaults, a quick Amharic scan without
review, and a saved history with duplicate detection.

## License

MIT — see [LICENSE](LICENSE).
