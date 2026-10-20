# Host integration

## Scanning from a host app

One call opens the scanner full screen and returns the plate:

```dart
final result = await EtPlateReader.scan(
  context,
  options: const PlateScannerOptions(),  // steps shown
  strings: null,                          // texts: by locale when null
  theme: null,                            // colours: the app's theme when null
);
```

`PlateScanResult`: `record` (code, region, serial, category via
`serviceType`, `layout` one-row / two-row, `confidence`, `editedByUser`),
`plate` (`2-AA-B05475`), `plateImage` (JPEG crop of the plate) and
`photoPath` (the full photo, in the cache — copy it to keep it). `null` when
the user closes the scanner.

### Steps — `PlateScannerOptions`

| Option | Default | Effect |
|---|---|---|
| `confirmArea` | `ConfirmAreaMode.never` | `always`: let the user drag the plate box before reading; `auto`: only when it couldn't be fitted to the plate |
| `showReview` | `true` | `false`: a valid reading returns at once; one with problems is still shown, so a wrong plate is never returned unseen |
| `allowEdit` | `true` | Show the edit button on the result |
| `showTorch` | `true` | Torch button while scanning |
| `autoCapture` | `true` | Capture once the plate holds still (the shutter is always shown) |

### Texts — `PlateScannerStrings`

English (`PlateScannerStrings.en()`) and Amharic (`.am()`) are built in and
picked from the app's locale (`am` → Amharic). Pass your own set for any
other language, or change a few:

```dart
strings: const PlateScannerStrings.en().copyWith(done: 'Use plate'),
```

For an Amharic app add `flutter_localizations` and
`GlobalMaterialLocalizations.delegate` (Flutter's own widgets need them).
Notes generated with a reading (e.g. "by colour", "embassy 06 · Turkey")
are English.

### Look — `PlateScannerTheme`

The **Done** button and highlights use the app's `colorScheme.primary` /
`onPrimary`, the result sheet uses `colorScheme.surface`, and text uses the
app's fonts. The camera screen stays dark. Override `accent` / `onAccent`;
`confirmed` and `sectionColors` only apply when `confirmArea` shows the
plate box.

### Own layout

`PlateScannerView` embeds the scanner in your own screen (same `options`,
`strings`, `theme`); you then own a `PlateReaderController` and dispose it.
`overlayBuilder` replaces the controls entirely.

## Rules

- Import only `package:et_plate_reader/et_plate_reader.dart` and `persistence.dart`.
- Gate the entry button with `PlateReader.checkAvailability()` (camera-free).
- With `PlateScannerView`: handle `onError` (camera-open failures), and use one `PlateReaderController` per scan screen, `dispose()`d when the route closes. `EtPlateReader.scan` does both.
- Physical device only. Emulators have no usable camera for OCR.

## Controller parameters (`PlateScannerView` only)

| Parameter | Default | Effect |
|---|---|---|
| `stableFrames` | 3 | Steady detections before auto-capture |
| `autoCapture` | true | `false` = the user taps the shutter |
| `recordSessions` | debug builds | Write a log per scan in `cache/et_plate_logs/` |
| `regionOfInterest` | set by the view | Normalized area of the preview searched for the plate |
| `parser` | `EthiopianPlateParser()` | `requireRegion: false` accepts plates without a region |

## Android

- `minSdk` ≥ 24. The plugin declares `CAMERA` and `camera.any` (`required=false`).
- ML Kit's Latin model is bundled in the APK (~4 MB per ABI); no download step.
- Works with Android Gradle plugin 8.x (tested with 8.11 and the app's
  `permission_handler` 12) and 9.x.
- Only if the app resolves `permission_handler_android` 14.x: that needs
  **compileSdk 37**, AGP 9, Gradle 9.3.1 and AGP's built-in Kotlin (leave
  `android.builtInKotlin` unset). API 37 installs as platform
  `android-37.0`, so use:

  ```kotlin
  compileSdk {
      version = release(37) { minorApiLevel = 0 }
  }
  ```

  See `example/android` for a working setup.

## iOS

- iOS 15.0+. Set `platform :ios, '15.0'` in the host `Podfile`.
- Add `NSCameraUsageDescription` to `Info.plist`.
- Add the `PERMISSION_CAMERA=1` preprocessor macro for `permission_handler`
  in the `Podfile` `post_install` block (see permission_handler docs).
