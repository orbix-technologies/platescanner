# Host integration

## Rules

- Import only `package:et_plate_reader/et_plate_reader.dart` and `persistence.dart`.
- Gate the entry button with `PlateReader.checkAvailability()` (camera-free).
- Still handle `onError`: permission denial and camera-open failures arrive there.
- One `PlateReaderController` per scan screen; `dispose()` it when the route closes.
- Physical device only. Emulators have no usable camera for OCR.

## Tuning

| Parameter | Default | Effect |
|---|---|---|
| `stableFrames` | 4 | Identical valid frames before auto-lock |
| `minConfidence` | 0.7 | Mean confidence over those frames |
| `autoLock` | true | `false` = user must tap *Use this reading* |
| `regionOfInterest` | (0.05, 0.2)–(0.95, 0.8) | Normalized area of the visible preview that is parsed |
| `parser` | `EthiopianPlateParser()` | `requireRegion: false` accepts plates without a region |

## Android

- `minSdk` ≥ 24. The plugin declares `CAMERA` and `camera.any` (`required=false`).
- ML Kit's Latin model is bundled in the APK (~4 MB per ABI); no download step.
- `permission_handler_android` 14.x needs **compileSdk 37**, AGP 9, Gradle 9.3.1 and
  AGP's built-in Kotlin (leave `android.builtInKotlin` unset). API 37 installs as
  platform `android-37.0`, so use:

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
