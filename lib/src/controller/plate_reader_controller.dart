import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_area_detector.dart';
import '../parsing/plate_arranger.dart';
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
    NormalizedRect regionOfInterest =
        const NormalizedRect(0.07, 0.25, 0.93, 0.6),
  })  : _roi = regionOfInterest,
        _service = service ?? PlateRecognitionServiceFactory.create(),
        _logger = logger ?? Logger(level: Level.off),
        _requestCameraPermission =
            requestCameraPermission ?? _defaultRequestCameraPermission,
        _parser = parser,
        _arranger = PlateArranger(parser: parser),
        _detector = detector,
        _tracker = PlateAreaTracker(stableFrames: stableFrames);

  final PlateRecognitionService _service;
  final Logger _logger;
  final Future<bool> Function() _requestCameraPermission;
  final EthiopianPlateParser _parser;
  final PlateArranger _arranger;
  final PlateAreaDetector _detector;
  final PlateAreaTracker _tracker;

  /// Whether a steady detected area freezes the frame automatically.
  final bool autoCapture;

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
  CapturedFrame? _frame;
  NormalizedRect? _area;
  PlateArrangement? _arrangement;
  PlateCandidate? _candidate;
  String? _draftCode;
  String? _draftRegion;
  String? _draftSerial;
  bool _edited = false;
  bool _capturing = false;
  PlateLocation? _location;
  String? _description;
  String? _error;
  bool _isLoading = false;
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

  /// Progress towards auto-capture of a steady area (`0.0`–`1.0`).
  double get detectionProgress => _tracker.progress;

  /// Step 2+: the frozen frame.
  CapturedFrame? get capturedFrame => _frame;

  /// Step 2+: the plate area on [capturedFrame] (normalized), as adjusted.
  NormalizedRect? get plateArea => _area;

  /// Step 4: characters arranged as on the plate.
  PlateArrangement? get arrangement => _arrangement;

  /// Step 4: the reading the arrangement implies (before user edits).
  PlateCandidate? get candidate => _candidate;

  /// Draft code-box value in [ScanPhase.review] (may be user-edited).
  String? get draftCode => _draftCode;

  /// Draft region code in [ScanPhase.review] (may be user-edited).
  String? get draftRegionCode => _draftRegion;

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
    final area = _detector.detect(lines);
    final stable = _tracker.add(area);
    _detectedArea = area;
    _notify();
    if (stable && autoCapture) unawaited(captureArea());
  }

  void _onPlatformError(String message) {
    if (_disposed) return;
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
      final proposed = _detectedArea ?? _roi;
      final frame = await _service.captureFrame();
      await _service.pause();
      if (_phase != ScanPhase.detecting) return false;
      _frame = frame;
      _area = proposed;
      _phase = ScanPhase.confirmingArea;
      _notify();
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
    final frame = _frame;
    final area = _area;
    if (_phase != ScanPhase.confirmingArea || frame == null || area == null) {
      return;
    }
    _phase = ScanPhase.reading;
    _notify();
    try {
      final ocr = await _service.recognizeArea(frame.path, area);
      if (_phase != ScanPhase.reading) return;
      final result = _arranger.arrange(ocr);
      _arrangement = result.arrangement;
      _candidate = result.candidate;
      _draftCode = result.candidate.code;
      _draftRegion = result.candidate.regionCode;
      _draftSerial = result.candidate.serial;
      _edited = false;
      _phase = ScanPhase.review;
      _notify();
    } catch (e, st) {
      _logger.e('Area read failed', error: e, stackTrace: st);
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
    _error = null;
    _reset();
    _phase = ScanPhase.detecting;
    _notify();
    await _service.start();
  }

  /// Back to step 2 from review: adjust the area on the same frame.
  void adjustAgain() {
    if (_phase != ScanPhase.review) return;
    _phase = ScanPhase.confirmingArea;
    _notify();
  }

  /// Replace draft fields in review. Pass only the fields being changed.
  ///
  /// [serial] is normalised (`a 12345` → `A12345`); an unparseable value is
  /// kept as typed so [draftIssues] reports it.
  void editField({String? code, String? regionCode, String? serial}) {
    if (_phase != ScanPhase.review) return;
    if (code != null) _draftCode = code.trim().toUpperCase();
    if (regionCode != null) _draftRegion = regionCode;
    if (serial != null) {
      _draftSerial = _parser.normalizeSerial(serial) ?? serial.toUpperCase();
    }
    _edited = true;
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
    );
    _phase = ScanPhase.confirmed;
    _notify();
    return record;
  }

  /// End the session without a result.
  Future<void> cancelSession() async {
    if (_phase == ScanPhase.idle) return;
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
    _frame = null;
    _area = null;
    _arrangement = null;
    _candidate = null;
    _draftCode = null;
    _draftRegion = null;
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
    _disposed = true;
    unawaited(_frameSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_service.dispose());
    super.dispose();
  }
}
