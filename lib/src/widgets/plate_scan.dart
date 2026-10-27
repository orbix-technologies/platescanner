import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../controller/plate_reader_controller.dart';
import '../models/plate_record.dart';
import '../patrol/patrol_controller.dart';
import '../patrol/patrol_tracker.dart';
import '../patrol/patrol_view.dart';
import '../segmentation/segment_capture.dart';
import 'plate_scanner_options.dart';
import 'plate_scanner_strings.dart';
import 'plate_scanner_view.dart';

/// What [EtPlateReader.scan] returns: the confirmed reading and a photo of
/// the plate.
@immutable
class PlateScanResult {
  /// Creates a result.
  const PlateScanResult({
    required this.record,
    this.plateImage,
    this.photoPath,
  });

  /// The reading: code, region, number, category ([PlateRecord.serviceType]),
  /// layout, confidence and whether the user corrected it
  /// ([PlateRecord.editedByUser]).
  final PlateRecord record;

  /// JPEG of the plate, cropped from the photo; null if it couldn't be made.
  final Uint8List? plateImage;

  /// The full photo on disk (in the app's cache; copy it to keep it).
  final String? photoPath;

  /// The plate as text, e.g. `2-AA-B05475`.
  String get plate => [
        record.code,
        if (record.regionCode != null) record.regionCode,
        record.serial,
      ].join('-');
}

/// Entry point for host apps.
abstract final class EtPlateReader {
  /// Opens the scanner full screen and returns the confirmed plate, or null
  /// when the user closes it.
  ///
  /// Texts follow the app's locale (English or Amharic built in) unless
  /// [strings] is given; colours follow the app's theme unless [theme]
  /// overrides them; [options] picks the steps shown. Camera permission is
  /// asked for, with a settings link when denied.
  static Future<PlateScanResult?> scan(
    BuildContext context, {
    PlateScannerOptions options = const PlateScannerOptions(),
    PlateScannerStrings? strings,
    PlateScannerTheme? theme,
    PlateLocation? location,
    bool? recordSessions,
  }) =>
      Navigator.of(context, rootNavigator: true).push<PlateScanResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _ScanPage(
            options: options,
            strings: strings,
            theme: theme,
            location: location,
            recordSessions: recordSessions,
          ),
        ),
      );

  /// Patrol: opens the camera full screen and reads every plate it passes
  /// (walking or riding past parked vehicles), with no taps. Each vehicle
  /// is reported once, after it has passed, to [onVehicle] — and again when
  /// its photo has been read in full (code and region added).
  /// [onVehicleRemoved] gets a reported vehicle that turned out to be
  /// another one seen twice (merged into it): delete it if you saved it.
  ///
  /// Returns the vehicles read, newest first, when the user taps Finish;
  /// null when they close it. Vehicles with an uncertain number have
  /// [PatrolVehicle.needsCheck] set.
  static Future<List<PatrolVehicle>?> patrol(
    BuildContext context, {
    void Function(PatrolVehicle vehicle)? onVehicle,
    void Function(PatrolVehicle vehicle)? onVehicleRemoved,
    PlateScannerStrings? strings,
    PlateScannerTheme? theme,
    bool? recordSessions,
  }) =>
      Navigator.of(context, rootNavigator: true).push<List<PatrolVehicle>>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _PatrolPage(
            onVehicle: onVehicle,
            onVehicleRemoved: onVehicleRemoved,
            strings: strings,
            theme: theme,
            recordSessions: recordSessions,
          ),
        ),
      );
}

class _PatrolPage extends StatefulWidget {
  const _PatrolPage({
    required this.onVehicle,
    required this.onVehicleRemoved,
    required this.strings,
    required this.theme,
    required this.recordSessions,
  });

  final void Function(PatrolVehicle vehicle)? onVehicle;
  final void Function(PatrolVehicle vehicle)? onVehicleRemoved;
  final PlateScannerStrings? strings;
  final PlateScannerTheme? theme;
  final bool? recordSessions;

  @override
  State<_PatrolPage> createState() => _PatrolPageState();
}

class _PatrolPageState extends State<_PatrolPage> {
  late final PatrolController _controller = PatrolController(
    onVehicle: widget.onVehicle,
    onVehicleRemoved: widget.onVehicleRemoved,
    recordSessions: widget.recordSessions,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: PatrolView(
          controller: _controller,
          strings: widget.strings,
          theme: widget.theme,
          onFinish: (all) => Navigator.of(context).pop(all),
          onClose: () => Navigator.of(context).pop(),
        ),
      );
}

class _ScanPage extends StatefulWidget {
  const _ScanPage({
    required this.options,
    required this.strings,
    required this.theme,
    required this.location,
    required this.recordSessions,
  });

  final PlateScannerOptions options;
  final PlateScannerStrings? strings;
  final PlateScannerTheme? theme;
  final PlateLocation? location;
  final bool? recordSessions;

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  late final PlateReaderController _controller = PlateReaderController(
    autoCapture: widget.options.autoCapture,
    recordSessions: widget.recordSessions,
  );
  bool _closing = false;

  Future<void> _done(PlateRecord record) async {
    if (_closing) return;
    _closing = true;
    final frame = _controller.capturedFrame;
    final area = _controller.plateArea;
    Uint8List? image;
    if (frame != null && area != null) {
      try {
        image = await cropPlateJpeg(frame.path, area);
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.of(context).pop(PlateScanResult(
      record: record,
      plateImage: image,
      photoPath: frame?.path,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PlateScannerView(
        controller: _controller,
        options: widget.options,
        strings: widget.strings,
        theme: widget.theme,
        initialLocation: widget.location,
        onPlateConfirmed: _done,
        onCancel: () {
          if (!_closing) Navigator.of(context).pop();
        },
      ),
    );
  }
}
