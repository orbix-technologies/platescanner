import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../diagnostics/session_log.dart';
import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_area_detector.dart';
import '../parsing/plate_arranger.dart';
import '../parsing/plate_section_reader.dart';
import '../segmentation/plate_segmenter.dart';
import '../segmentation/segment_capture.dart';
import '../recognition/plate_recognition_service.dart';

const _uuid = Uuid();

/// Scan session phase for overlay UI.
///
/// The flow is: [detecting] the plate area → [confirmingArea] (user accepts
/// or adjusts it) → [reading] the characters inside it → [review] of the
/// arranged plate → [confirmed].
enum ScanPhase {
  /// No active session.
  idle,

  /// Permission / camera start-up in progress.
  initializing,

  /// Step 1: looking for the plate area in the live preview.
  detecting,

  /// Step 2: frame frozen; the user confirms or adjusts the plate area.
  confirmingArea,

  /// Step 3: reading the characters inside the confirmed area.
  reading,

  /// Step 4: characters arranged as on the plate; the user can edit / Done.
  review,

  /// The reading was confirmed and returned as a [PlateRecord].
  confirmed,

  /// Start-up, the camera or reading failed; see [PlateReaderController.error].
  error,
}

/// Session controller for reading one Ethiopian plate.
///
/// Storage-agnostic: [confirm] returns an in-memory [PlateRecord]. Drive UI
/// with [Listenable] / [ListenableBuilder], or embed [PlateScannerView].
class PlateReaderController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// The plate area is searched only inside [regionOfInterest] (normalized
  /// coordinates of the visible preview; [PlateScannerView] sets it to its
  /// guide box). With [autoCapture], the frame freezes once the detected
  /// area holds still for [stableFrames] frames; otherwise the user captures.
  PlateReaderController({
    PlateRecognitionService? service,
    Logger? logger,
    Future<bool> Function()? requestCameraPermission,
    EthiopianPlateParser parser = const EthiopianPlateParser(),
    PlateAreaDetector detector = const PlateAreaDetector(),
    int stableFrames = 3,
    this.autoCapture = true,
    bool? recordSessions,
    NormalizedRect regionOfInterest =
        const NormalizedRect(0.07, 0.25, 0.93, 0.6),
    this.discardDelay = const Duration(seconds: 30),
  })  : recordSessions = recordSessions ?? kDebugMode,
        _roi = regionOfInterest,
        _service = service ?? PlateRecognitionServiceFactory.create(),
        _logger = logger ?? Logger(level: Level.off),
        _requestCameraPermission =
            requestCameraPermission ?? _defaultRequestCameraPermission,
        _parser = parser,
        _arranger = PlateArranger(parser: parser),
        _sectionReader = PlateSectionReader(parser: parser),
        _detector = detector,
        _tracker = PlateAreaTracker(stableFrames: stableFrames);

  final PlateRecognitionService _service;
  final Logger _logger;
  final Future<bool> Function() _requestCameraPermission;
  final EthiopianPlateParser _parser;
  final PlateArranger _arranger;
  final PlateSectionReader _sectionReader;
  final PlateAreaDetector _detector;
  final PlateAreaTracker _tracker;

  /// Whether a steady detected area freezes the frame automatically.
  final bool autoCapture;

  /// Whether each session is written to a diagnostic log (see [SessionLog]).
  /// On by default in debug builds.
  final bool recordSessions;

  SessionLog? _log;

  NormalizedRect _roi;

  /// Area of the visible preview searched for the plate (normalized).
  ///
  /// OCR lines not entirely inside it are ignored, so nothing outside the
  /// guide box is detected. Changing it restarts the stability count.
  NormalizedRect get regionOfInterest => _roi;

  set regionOfInterest(NormalizedRect value) {
    if (value == _roi) return;
    _roi = value;
    _tracker.reset();
  }

  /// Slack for a line touching the box edge (normalized units).
  static const _roiTolerance = 0.01;

  /// Smallest plate area the user can adjust to (normalized).
  static const _minArea = 0.04;

  static Future<bool> _defaultRequestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  ScanPhase _phase = ScanPhase.idle;
  NormalizedRect? _detectedArea;

  /// The detected area is framed on a new national number (`ABC1234`).
  bool _detectedNational = false;

  /// The detected area is the plate detector model's box (the whole plate),
  /// not one guessed from OCR text boxes.
  bool _detectedByModel = false;
  CapturedFrame? _frame;

  /// The confirmed record took the photo ([PlateRecord.imagePath]): it is
  /// the host's to keep or delete.
  bool _frameHandedOver = false;

  /// How long the photo of a scan that ended without a result is kept
  /// before it is deleted, so reads still running on it (snap,
  /// segmentation, OCR) finish first.
  final Duration discardDelay;

  /// Deletes the still of a scan that ended without a result (retake,
  /// cancel, closed). Session logs, when recorded, keep their own copy.
  void _discard(CapturedFrame? frame) {
    if (frame == null) return;
    final saved = _log?.save() ?? Future<void>.value();
    unawaited(
        saved.then((_) => Future<void>.delayed(discardDelay)).then((_) async {
      try {
        final f = File(frame.path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Best effort: the OS clears the cache directory too.
      }
    }));
  }

  NormalizedRect? _area;
  PlateArrangement? _arrangement;
  AreaOcr? _areaOcr;
  PlateCandidate? _candidate;
  String? _draftCode;
  String? _draftRegion;
  String? _draftEmbassy;
  String? _draftSerial;
  bool _edited = false;
  bool _capturing = false;
  PlateLocation? _location;
  String? _description;
  String? _error;
  PlateReaderErrorCode? _errorCode;
  bool _isLoading = false;

  /// Area snapping after capture: running, and whether it moved the area
  /// onto a found plate outline.
  bool _snapping = false;
  bool _areaSnapped = false;
  Future<void>? _snap;
  bool _confirming = false;
  bool _isSupported = false;
  bool _torchOn = false;
  bool _initialized = false;
  bool _disposed = false;
  Completer<void>? _initializeCompleter;
  StreamSubscription<OcrFrame>? _frameSub;
  StreamSubscription<String>? _errorSub;

  /// Current phase.
  ScanPhase get phase => _phase;

  /// Step 1: plate area found in the latest frame (normalized), or `null`.
  NormalizedRect? get detectedArea => _detectedArea;

  /// Step 1: the plate found is too far to read (narrower than
  /// [minPlateWidth] of the frame).
  bool get plateTooSmall =>
      _detectedArea != null && _detectedArea!.width < minPlateWidth;

  /// Narrowest detected area (of the frame's width) read reliably: plates
  /// read well at about 0.45, and not at 0.09–0.13 (session logs of
  /// 2026-10-27).
  static const minPlateWidth = 0.22;

  /// Progress towards auto-capture of a steady area (`0.0`–`1.0`).
  double get detectionProgress => _tracker.progress;

  /// Step 2+: the frozen frame.
  CapturedFrame? get capturedFrame => _frame;

  /// Step 2+: the plate area on [capturedFrame] (normalized), as adjusted.
  NormalizedRect? get plateArea => _area;

  /// Step 3: raw OCR of the confirmed area (diagnostics).
  AreaOcr? get areaOcr => _areaOcr;

  /// Step 4: characters arranged as on the plate.
  PlateArrangement? get arrangement => _arrangement;

  /// Step 4: the reading the arrangement implies (before user edits).
  PlateCandidate? get candidate => _candidate;

  /// Draft code-box value in [ScanPhase.review] (may be user-edited).
  String? get draftCode => _draftCode;

  /// Draft region code in [ScanPhase.review] (may be user-edited).
  String? get draftRegionCode => _draftRegion;

  /// Diplomatic plates: the embassy number in review (`132`), or `null`.
  String? get draftEmbassyCode => _draftEmbassy;

  /// Draft serial in [ScanPhase.review] (may be user-edited).
  String? get draftSerial => _draftSerial;

  /// Validation problems with the draft; empty when [canConfirm].
  List<PlateIssue> get draftIssues => _parser.validate(
        code: _draftCode,
        regionCode: _draftRegion,
        serial: _draftSerial,
      );

  /// True in review when the draft validates.
  bool get canConfirm => _phase == ScanPhase.review && draftIssues.isEmpty;

  /// Kind of the last error, when it was a [PlateReaderException] (e.g.
  /// [PlateReaderErrorCode.permissionDenied]), so a UI can explain it.
  PlateReaderErrorCode? get errorCode => _errorCode;

  /// True while the proposed area is being snapped to the plate on the
  /// still (right after capture).
  bool get isSnappingArea => _snapping;

  /// True when the area was snapped onto a found plate outline — a UI can
  /// then skip asking the user to confirm it.
  bool get areaSnapped => _areaSnapped;

  /// Whether the torch is on.
  bool get torchOn => _torchOn;

  /// Last user-facing error message, if any.
  String? get error => _error;

  /// True while [initialize] is in progress.
  bool get isLoading => _isLoading;

  /// True after a successful support check.
  bool get isSupported => _isSupported;

  /// Whether a session is open.
  bool get hasActiveSession => const {
        ScanPhase.detecting,
        ScanPhase.confirmingArea,
        ScanPhase.reading,
        ScanPhase.review,
      }.contains(_phase);

  /// Underlying platform service (advanced / tests).
  PlateRecognitionService get service => _service;

  /// Parser used for field reading and validation.
  EthiopianPlateParser get parser => _parser;

  /// Request camera permission, check support and subscribe to the backend.
  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    if (_initializeCompleter != null) return _initializeCompleter!.future;
    final completer = _initializeCompleter = Completer<void>();
    _isLoading = true;
    _phase = ScanPhase.initializing;
    _error = null;
    _errorCode = null;
    _notify();

    try {
      if (!await _requestCameraPermission()) {
        throw PlateReaderException(
          PlateReaderErrorCode.permissionDenied,
          'Camera permission is required to read plates.',
        );
      }
      _isSupported = await _service.isSupported();
      if (!_isSupported) {
        throw PlateReaderException(
          PlateReaderErrorCode.unsupportedDevice,
          'This device cannot read plates.',
        );
      }
      await _service.initialize();
      _frameSub = _service.frameStream.listen(_onFrame);
      _errorSub = _service.platformErrorStream.listen(_onPlatformError);
      _initialized = true;
      _phase = ScanPhase.idle;
      completer.complete();
    } catch (e, st) {
      _logger.e('Plate reader init failed', error: e, stackTrace: st);
      _error = e is PlateReaderException ? e.message : 'Failed to start: $e';
      _errorCode = e is PlateReaderException ? e.code : null;
      _phase = ScanPhase.error;
      _initializeCompleter = null;
      completer.completeError(e, st);
    } finally {
      _isLoading = false;
      _notify();
    }
    return completer.future;
  }

  /// Open a session and start looking for the plate area (step 1).
  Future<void> startSession({PlateLocation? location}) async {
    _ensureInitialized();
    _location = location;
    _description = null;
    _reset();
    _log = recordSessions ? SessionLog() : null;
    _log?.event('start', {'roi': SessionLog.rect(_roi)});
    unawaited(_log?.save());
    _phase = ScanPhase.detecting;
    _notify();
    try {
      await _service.ensureReady();
      await _service.start();
    } catch (e) {
      _onPlatformError('Camera did not start: $e');
    }
  }

  void _onFrame(OcrFrame frame) {
    if (_disposed || _phase != ScanPhase.detecting) return;
    final lines = frame.lines
        .where((l) => _roi.contains(l.box, tolerance: _roiTolerance))
        .toList(growable: false);
    final detection = _detector.detectDetailed(lines);
    // The detector model frames the whole plate (top row of two-row plates
    // included) whatever the light; text boxes are the fallback.
    final plate = _bestPlate(frame.plates);
    final area = plate?.box ?? detection?.area;
    _detectedNational = detection?.national ?? false;
    _detectedByModel = plate != null;
    _log?.detection(lines, area, plates: frame.plates);
    final stable = _tracker.add(area);
    _detectedArea = area;
    _notify();
    if (stable && autoCapture) unawaited(captureArea());
  }

  /// The most confident detector plate centred inside the guide box.
  DetectedPlate? _bestPlate(List<DetectedPlate> plates) {
    for (final p in plates) {
      if (_roi.containsCenterOf(p.box)) return p;
    }
    return null;
  }

  /// The still's plate that best overlaps [proposed], else its most
  /// confident plate inside the guide box.
  NormalizedRect? _plateOnStill(
    List<DetectedPlate> plates,
    NormalizedRect proposed,
  ) {
    DetectedPlate? best;
    var bestOverlap = 0.0;
    for (final p in plates) {
      final overlap = _iou(p.box, proposed);
      if (overlap > bestOverlap) {
        best = p;
        bestOverlap = overlap;
      }
    }
    return (best ?? _bestPlate(plates))?.box;
  }

  static double _iou(NormalizedRect a, NormalizedRect b) {
    final w = math.min(a.right, b.right) - math.max(a.left, b.left);
    final h = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
    if (w <= 0 || h <= 0) return 0;
    final inter = w * h;
    return inter / (a.width * a.height + b.width * b.height - inter);
  }

  void _onPlatformError(String message) {
    if (_disposed) return;
    _log?.event('error', {'message': message, 'phase': _phase.name});
    unawaited(_log?.save());
    _error = message;
    _phase = ScanPhase.error;
    _notify();
  }

  /// Step 1 → 2: freeze the frame and propose the plate area. Uses the
  /// guide box when no plate was detected. Returns `false` if not detecting.
  Future<bool> captureArea() async {
    if (_phase != ScanPhase.detecting || _capturing) return false;
    _capturing = true;
    try {
      var proposed = _detectedArea ?? _roi;
      final frame = await _service.captureFrame();
      await _service.pause();
      if (_phase != ScanPhase.detecting) {
        _discard(frame);
        return false;
      }
      // The plate as found on the still itself: the live box may be from
      // an earlier frame.
      final onStill = _plateOnStill(frame.plates, proposed);
      if (onStill != null) proposed = onStill;
      final byModel = onStill != null || _detectedByModel;
      _frame = frame;
      _area = proposed;
      _log?.frame(frame);
      _log?.event('capture', {
        'frame': frame.path,
        'width': frame.width,
        'height': frame.height,
        'detected': SessionLog.rect(_detectedArea),
        'proposed': SessionLog.rect(proposed),
        'national': _detectedNational,
        'byModel': byModel,
        'stillPlates': [
          for (final p in frame.plates)
            {...?SessionLog.rect(p.box), 'score': p.score},
        ],
        'auto': _tracker.progress >= 1,
      });
      // Set before the phase changes, so a UI never sees the area as
      // "not snapped" while the snap is about to run.
      _snapping = !_detectedNational && !byModel;
      _areaSnapped = false;
      _phase = ScanPhase.confirmingArea;
      _notify();
      // The new national plate is framed from its number line already; its
      // pale, hatched characters mislead the outline search. The model's box
      // is the whole plate already; the outline search can lose a shaded or
      // two-row top.
      if (!_detectedNational && !byModel) {
        final snap = _snapArea(frame, proposed, _detectedArea);
        _snap = snap;
        unawaited(snap);
      }
      return true;
    } catch (e) {
      _onPlatformError(
        e is PlateReaderException ? e.message : 'Capture failed: $e',
      );
      return false;
    } finally {
      _capturing = false;
    }
  }

  /// Step 1b: snaps the proposed area to the plate's outline on the still
  /// (the live area is loose and may come from an earlier frame; the
  /// detection at the moment of the still is tried when nothing is found
  /// near it). Applied only while the user hasn't moved the box or retaken.
  Future<void> _snapArea(
    CapturedFrame frame,
    NormalizedRect proposed,
    NormalizedRect? latest,
  ) async {
    final watch = Stopwatch()..start();
    NormalizedRect? snapped;
    _snapping = true;
    try {
      snapped = await snapCaptureArea(
        frame.path,
        proposed,
        fallback: latest == proposed ? null : latest,
      );
    } catch (e) {
      _log?.event('snapError', {'error': '$e'});
      return;
    } finally {
      _snapping = false;
      if (!_disposed) _notify();
    }
    _log?.event('snap', {
      'area': SessionLog.rect(snapped),
      'ms': watch.elapsedMilliseconds,
    });
    if (_disposed || snapped == null) return;
    if (_phase != ScanPhase.confirmingArea ||
        !identical(_frame, frame) ||
        _area != proposed) {
      return;
    }
    _area = snapped;
    _areaSnapped = true;
    _notify();
  }

  /// How long confirming waits for the snap still running.
  static const snapWait = Duration(seconds: 2);

  /// Step 2: replace the proposed plate area (normalized, clamped to the
  /// frame). Ignored outside [ScanPhase.confirmingArea] or when too small.
  void adjustArea(NormalizedRect area) {
    if (_phase != ScanPhase.confirmingArea) return;
    double c(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
    final next = NormalizedRect(
      c(area.left),
      c(area.top),
      c(area.right),
      c(area.bottom),
    );
    if (next.width < _minArea || next.height < _minArea) return;
    _area = next;
    _notify();
  }

  /// Step 2 → 3 → 4: read every character inside the confirmed area and
  /// arrange them as on the plate.
  Future<void> confirmArea() async {
    if (_phase != ScanPhase.confirmingArea || _confirming) return;
    // Confirmed straight after the capture (no confirm step): the snap to
    // the plate's outline is still running, and the loose proposed area
    // would be read instead, with the bumper and chrome around the plate
    // (scans of 2026-10-26: snapped right, read wrong). Its result first.
    final snap = _snap;
    if (_snapping && snap != null) {
      // Once: the snap's own notification would confirm again meanwhile.
      _confirming = true;
      try {
        await snap.timeout(snapWait);
      } catch (_) {
      } finally {
        _confirming = false;
      }
    }
    final frame = _frame;
    final area = _area;
    if (_phase != ScanPhase.confirmingArea || frame == null || area == null) {
      return;
    }
    _phase = ScanPhase.reading;
    _log?.event('confirmArea', {'area': SessionLog.rect(area)});
    _notify();
    try {
      // Sections from the image itself: each one cut out and read alone,
      // so a vertical stack can't be read into the number. The whole-area
      // OCR still measures colours, and is the fallback when no number is
      // found in the image.
      PlateSegmentation? seg;
      try {
        seg = await segmentCapture(frame.path, area);
      } catch (e) {
        _log?.event('segmentationError', {'error': '$e'});
      }
      if (seg != null) {
        _log?.event('segmentation', SessionLog.segmentation(seg));
      }
      final segmented = seg != null && seg.found;
      final ocr = await _service.recognizeArea(
        frame.path,
        area,
        sectionPasses: !segmented,
      );
      _log?.event('areaOcr', SessionLog.areaOcr(ocr));
      if (_phase != ScanPhase.reading) return;
      _areaOcr = ocr;

      ({PlateArrangement arrangement, PlateCandidate candidate}) result;
      if (segmented) {
        var crops = _sectionReader.cropsFor(seg, area);
        var reads = await _service
            .readCrops(frame.path, [for (final c in crops) c.spec]);
        result = _sectionReader.read(seg, crops, reads, ocr);
        if (result.arrangement.number.value.isEmpty) {
          // The whole-number reads disagreed: read each digit alone too.
          final digits = _sectionReader.cropsFor(seg, area, digits: true);
          final more = await _service
              .readCrops(frame.path, [for (final c in digits) c.spec]);
          crops = [...crops, ...digits];
          reads = [...reads, ...more];
          result = _sectionReader.read(seg, crops, reads, ocr);
        }
        _log?.event('crops', {'crops': SessionLog.crops(crops, reads)});
        if (_phase != ScanPhase.reading) return;
      } else {
        result = _arranger.arrange(ocr);
      }
      _arrangement = result.arrangement;
      _candidate = result.candidate;
      _draftCode = result.candidate.code;
      _draftRegion = result.candidate.regionCode;
      _draftEmbassy = result.candidate.embassyCode;
      _draftSerial = result.candidate.serial;
      _edited = false;
      _log?.event('arranged', {
        ...SessionLog.arrangement(result.arrangement),
        'reading': SessionLog.candidate(result.candidate),
      });
      unawaited(_log?.save());
      _phase = ScanPhase.review;
      _notify();
    } catch (e, st) {
      _logger.e('Area read failed', error: e, stackTrace: st);
      // Retaken, cancelled or closed meanwhile (its photo may be gone).
      if (_phase != ScanPhase.reading) return;
      _onPlatformError(
        e is PlateReaderException ? e.message : 'Reading failed: $e',
      );
    }
  }

  /// Back to step 1 from any later step: discard the frame and detect again.
  Future<void> retake() async {
    if (!const {
      ScanPhase.confirmingArea,
      ScanPhase.reading,
      ScanPhase.review,
      ScanPhase.error,
    }.contains(_phase)) {
      return;
    }
    _log?.event('retake', {'from': _phase.name});
    await _log?.save();
    _log = recordSessions ? SessionLog() : null;
    _log?.event('start', {'roi': SessionLog.rect(_roi), 'after': 'retake'});
    unawaited(_log?.save());
    _error = null;
    _reset();
    _phase = ScanPhase.detecting;
    _notify();
    await _service.start();
  }

  /// Back to step 2 from review: adjust the area on the same frame.
  void adjustAgain() {
    if (_phase != ScanPhase.review) return;
    _log?.event('adjustAgain');
    _phase = ScanPhase.confirmingArea;
    _notify();
  }

  /// Replace draft fields in review. Pass only the fields being changed.
  ///
  /// [serial] is normalised (`a 12345` → `A12345`); an unparseable value is
  /// kept as typed so [draftIssues] reports it.
  void editField({
    String? code,
    String? regionCode,
    String? serial,
    String? embassyCode,
  }) {
    if (_phase != ScanPhase.review) return;
    if (embassyCode != null) {
      final e = embassyCode.replaceAll(RegExp(r'\D'), '');
      _draftEmbassy = e.isEmpty ? null : e;
    }
    if (code != null) _draftCode = code.trim().toUpperCase();
    if (regionCode != null) _draftRegion = regionCode;
    if (serial != null) {
      _draftSerial = _parser.normalizeSerial(serial) ?? serial.toUpperCase();
    }
    _edited = true;
    _log?.event('edit', {
      'code': code,
      'region': regionCode,
      'serial': serial,
      'embassy': embassyCode,
      'draft': [_draftCode, _draftEmbassy, _draftRegion, _draftSerial],
    });
    _notify();
  }

  /// Attach a host note to the reading.
  void setDescription(String description) {
    _description = description;
    _notify();
  }

  /// Attach / replace the GPS fix.
  void setLocation(PlateLocation location) {
    _location = location;
    _notify();
  }

  /// Done: confirm the reviewed reading and return it as a [PlateRecord].
  Future<PlateRecord> confirm() async {
    if (_phase != ScanPhase.review) {
      throw PlateReaderException(
        PlateReaderErrorCode.invalidState,
        'Nothing to confirm — confirm the plate area first.',
      );
    }
    final issues = draftIssues;
    if (issues.isNotEmpty) {
      throw PlateReaderException(
        PlateReaderErrorCode.invalidState,
        'Reading is incomplete: ${issues.map((i) => i.name).join(', ')}',
      );
    }
    final c = _candidate!;
    final record = PlateRecord(
      id: _uuid.v4(),
      code: _draftCode!,
      regionCode: _draftRegion,
      serial: _draftSerial!,
      layout: c.layout,
      rawText: c.rawText,
      confidence: c.confidence,
      capturedAt: DateTime.now(),
      editedByUser: _edited,
      imagePath: _frame?.path,
      location: _location,
      description: _description,
      // Only on diplomatic plates (the code may have been edited).
      embassyCode: _draftCode == 'CD' ? _draftEmbassy : null,
    );
    // The photo is the host's now (PlateRecord.imagePath).
    _frameHandedOver = true;
    _log?.event('done', {
      'record': record.canonical,
      'editedByUser': record.editedByUser,
    });
    unawaited(_log?.save());
    _phase = ScanPhase.confirmed;
    _notify();
    return record;
  }

  /// End the session without a result.
  Future<void> cancelSession() async {
    if (_phase == ScanPhase.idle) return;
    _log?.event('cancel', {'phase': _phase.name});
    unawaited(_log?.save());
    await _service.pause();
    _reset();
    _phase = _initialized ? ScanPhase.idle : _phase;
    _notify();
  }

  /// Toggle the torch.
  Future<void> toggleTorch() async {
    _torchOn = await _service.setTorch(!_torchOn);
    _notify();
  }

  void _reset() {
    _tracker.reset();
    _detectedArea = null;
    _detectedNational = false;
    _detectedByModel = false;
    _snapping = false;
    _areaSnapped = false;
    _snap = null;
    if (!_frameHandedOver) _discard(_frame);
    _frameHandedOver = false;
    _frame = null;
    _area = null;
    _arrangement = null;
    _areaOcr = null;
    _candidate = null;
    _draftCode = null;
    _draftRegion = null;
    _draftEmbassy = null;
    _draftSerial = null;
    _edited = false;
  }

  void _ensureInitialized() {
    if (_disposed) {
      throw PlateReaderException(
        PlateReaderErrorCode.invalidState,
        'Controller disposed',
      );
    }
    if (!_initialized) {
      throw PlateReaderException(
        PlateReaderErrorCode.invalidState,
        'Call initialize() before startSession()',
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // Closed with back, a route pop or the host going away mid-scan: keep
    // the attempt. (A finished, cancelled or never-started session is idle
    // or confirmed.)
    if (_phase != ScanPhase.idle && _phase != ScanPhase.confirmed) {
      _log?.event('closed', {'phase': _phase.name});
      unawaited(_log?.save());
    }
    if (!_frameHandedOver) _discard(_frame);
    _disposed = true;
    unawaited(_frameSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_service.dispose());
    super.dispose();
  }
}
