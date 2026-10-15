import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_stability_voter.dart';
import '../recognition/plate_recognition_service.dart';

const _uuid = Uuid();

/// Scan session phase for overlay UI.
enum ScanPhase {
  /// No active session.
  idle,

  /// Permission / camera / model start-up in progress.
  initializing,

  /// Reading frames, waiting for a stable valid plate.
  scanning,

  /// A reading is locked; the user can edit, rescan or confirm.
  locked,

  /// The reading was confirmed and returned as a [PlateRecord].
  confirmed,

  /// Start-up or the camera failed; see [PlateReaderController.error].
  error,
}

/// Session controller for reading one Ethiopian plate.
///
/// Storage-agnostic: [confirm] returns an in-memory [PlateRecord]. Drive UI
/// with [Listenable] / [ListenableBuilder], or embed [PlateScannerView].
class PlateReaderController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// A reading auto-locks after [stableFrames] consecutive identical valid
  /// frames whose mean confidence is at least [minConfidence]. Only OCR lines
  /// that lie entirely inside [regionOfInterest] (normalized coordinates of
  /// the visible preview) are parsed. [PlateScannerView] sets it to the guide
  /// box it draws.
  PlateReaderController({
    PlateRecognitionService? service,
    Logger? logger,
    Future<bool> Function()? requestCameraPermission,
    EthiopianPlateParser parser = const EthiopianPlateParser(),
    int stableFrames = 4,
    double minConfidence = 0.7,
    this.autoLock = true,
    NormalizedRect regionOfInterest =
        const NormalizedRect(0.07, 0.25, 0.93, 0.6),
  })  : _roi = regionOfInterest,
        _service = service ?? PlateRecognitionServiceFactory.create(),
        _logger = logger ?? Logger(level: Level.off),
        _requestCameraPermission =
            requestCameraPermission ?? _defaultRequestCameraPermission,
        _parser = parser,
        _voter = PlateStabilityVoter(
          stableFrames: stableFrames,
          minConfidence: minConfidence,
        );

  final PlateRecognitionService _service;
  final Logger _logger;
  final Future<bool> Function() _requestCameraPermission;
  final EthiopianPlateParser _parser;
  final PlateStabilityVoter _voter;

  /// Whether a stable reading locks automatically (else only [lockCurrent]).
  final bool autoLock;

  NormalizedRect _roi;

  /// Area of the visible preview that is read (normalized `0.0`–`1.0`).
  ///
  /// OCR lines that are not entirely inside it are ignored, so text outside
  /// the guide box is never read. Changing it restarts the stability vote.
  NormalizedRect get regionOfInterest => _roi;

  set regionOfInterest(NormalizedRect value) {
    if (value == _roi) return;
    _roi = value;
    _voter.reset();
  }

  /// Slack for a line touching the box edge (normalized units).
  static const _roiTolerance = 0.01;

  static Future<bool> _defaultRequestCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  ScanPhase _phase = ScanPhase.idle;
  PlateCandidate? _live;
  PlateCandidate? _locked;
  String? _draftCode;
  String? _draftRegion;
  String? _draftSerial;
  bool _edited = false;
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

  /// Latest per-frame reading while [ScanPhase.scanning], else `null`.
  PlateCandidate? get liveCandidate => _live;

  /// Reading that was locked, while [ScanPhase.locked].
  PlateCandidate? get lockedCandidate => _locked;

  /// Progress towards an auto-lock (`0.0`–`1.0`).
  double get lockProgress => _voter.progress;

  /// Draft code-box value while locked (may be user-edited).
  String? get draftCode => _draftCode;

  /// Draft region code while locked (may be user-edited).
  String? get draftRegionCode => _draftRegion;

  /// Draft serial while locked (may be user-edited).
  String? get draftSerial => _draftSerial;

  /// Validation problems with the draft; empty when [canConfirm].
  List<PlateIssue> get draftIssues => _parser.validate(
        code: _draftCode,
        regionCode: _draftRegion,
        serial: _draftSerial,
      );

  /// True when locked and the draft validates.
  bool get canConfirm => _phase == ScanPhase.locked && draftIssues.isEmpty;

  /// Whether the torch is on.
  bool get torchOn => _torchOn;

  /// Last user-facing error message, if any.
  String? get error => _error;

  /// True while [initialize] is in progress.
  bool get isLoading => _isLoading;

  /// True after a successful support check.
  bool get isSupported => _isSupported;

  /// Whether a session is open (scanning or locked).
  bool get hasActiveSession =>
      _phase == ScanPhase.scanning || _phase == ScanPhase.locked;

  /// Underlying platform service (advanced / tests).
  PlateRecognitionService get service => _service;

  /// Parser used for readings and draft validation.
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

  /// Open a scan session and start frame analysis.
  Future<void> startSession({PlateLocation? location}) async {
    _ensureInitialized();
    _location = location;
    _description = null;
    _resetReading();
    _phase = ScanPhase.scanning;
    _notify();
    try {
      await _service.ensureReady();
      await _service.start();
    } catch (e) {
      _onPlatformError('Camera did not start: $e');
    }
  }

  void _onFrame(OcrFrame frame) {
    if (_disposed || _phase != ScanPhase.scanning) return;
    final lines = frame.lines
        .where((l) => _roi.contains(l.box, tolerance: _roiTolerance))
        .toList(growable: false);
    if (lines.isEmpty) {
      if (_live != null) {
        _live = null;
        _notify();
      }
      return;
    }
    final candidate = _parser.parse(lines, codeHint: frame.codeHint);
    _live = candidate;
    final stable = _voter.add(candidate);
    if (stable != null && autoLock) {
      unawaited(_lock(stable));
    } else {
      _notify();
    }
  }

  void _onPlatformError(String message) {
    if (_disposed) return;
    _error = message;
    _phase = ScanPhase.error;
    _notify();
  }

  /// Lock the current live reading now, even if it does not validate yet
  /// (the user can fix fields). Returns `false` when nothing is in view.
  Future<bool> lockCurrent() async {
    final live = _live;
    if (_phase != ScanPhase.scanning || live == null) return false;
    await _lock(live);
    return true;
  }

  Future<void> _lock(PlateCandidate candidate) async {
    if (_phase != ScanPhase.scanning) return;
    _phase = ScanPhase.locked;
    _locked = candidate;
    _draftCode = candidate.code;
    _draftRegion = candidate.regionCode;
    _draftSerial = candidate.serial;
    _edited = false;
    _live = null;
    _notify();
    await _service.pause();
  }

  /// Confirm whatever is readable now: the locked draft, or — while
  /// scanning — the current live reading if it validates.
  Future<PlateRecord> confirmCurrent() async {
    if (_phase == ScanPhase.scanning) {
      final live = _live;
      if (live == null || !live.isValid) {
        throw PlateReaderException(
          PlateReaderErrorCode.invalidState,
          'No complete plate in the box yet.',
        );
      }
      await _lock(live);
    }
    return confirm();
  }

  /// Replace draft fields while locked. Pass only the fields being changed.
  ///
  /// [serial] is normalised (`a 12345` → `A12345`); an unparseable value is
  /// kept as typed so [draftIssues] reports it.
  void editField({String? code, String? regionCode, String? serial}) {
    if (_phase != ScanPhase.locked) return;
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

  /// Discard the locked reading and resume scanning.
  Future<void> rescan() async {
    if (_phase != ScanPhase.locked && _phase != ScanPhase.error) return;
    _error = null;
    _resetReading();
    _phase = ScanPhase.scanning;
    _notify();
    await _service.start();
  }

  /// Confirm the locked draft and return it as a [PlateRecord].
  Future<PlateRecord> confirm() async {
    if (_phase != ScanPhase.locked) {
      throw PlateReaderException(
        PlateReaderErrorCode.invalidState,
        'Nothing to confirm — lock a reading first.',
      );
    }
    final issues = draftIssues;
    if (issues.isNotEmpty) {
      throw PlateReaderException(
        PlateReaderErrorCode.invalidState,
        'Reading is incomplete: ${issues.map((i) => i.name).join(', ')}',
      );
    }
    final locked = _locked!;
    final record = PlateRecord(
      id: _uuid.v4(),
      code: _draftCode!,
      regionCode: _draftRegion,
      serial: _draftSerial!,
      layout: locked.layout,
      rawText: locked.rawText,
      confidence: locked.confidence,
      capturedAt: DateTime.now(),
      editedByUser: _edited,
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
    _resetReading();
    _phase = _initialized ? ScanPhase.idle : _phase;
    _notify();
  }

  /// Toggle the torch.
  Future<void> toggleTorch() async {
    _torchOn = await _service.setTorch(!_torchOn);
    _notify();
  }

  void _resetReading() {
    _voter.reset();
    _live = null;
    _locked = null;
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
