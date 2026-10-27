import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../diagnostics/session_log.dart';
import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_service_type.dart';
import '../recognition/plate_recognition_service.dart';
import '../segmentation/segment_capture.dart';
import 'patrol_refiner.dart';
import 'patrol_tracker.dart';

/// Patrol: reads every plate the camera passes, with no taps — one plate at
/// a time, in full.
///
/// Live frames go through a [PatrolTracker], which follows each plate and
/// its number. One of them is in focus: the nearest plate read in full
/// view. While it stays in view its photo is read like a single scan —
/// plate outline, sections, each section read — so its code, region and
/// number come out in whatever arrangement the plate has (one or two rows,
/// diplomatic, police, UN / AU, temporary, the new national plate). A
/// closer view is read again, up to [maxPhotos] times, and the best full
/// reading that agrees with the live number is kept.
class PatrolController extends ChangeNotifier {
  /// Creates a controller.
  PatrolController({
    PlateRecognitionService? service,
    Future<bool> Function()? requestCameraPermission,
    this.parser = const EthiopianPlateParser(requireRegion: false),
    this.onVehicle,
    this.onVehicleRemoved,
    bool? recordSessions,
  })  : _service = service ?? PlateRecognitionServiceFactory.create(),
        _requestPermission = requestCameraPermission ??
            (() async => (await Permission.camera.request()).isGranted),
        recordSessions = recordSessions ?? kDebugMode,
        _tracker = PatrolTracker(parser: parser);

  final PlateRecognitionService _service;
  final Future<bool> Function() _requestPermission;
  final PatrolTracker _tracker;

  /// Reads the plates.
  final EthiopianPlateParser parser;

  /// Called for each vehicle once it has passed, and again when its full
  /// reading (code / region) is added.
  final void Function(PatrolVehicle vehicle)? onVehicle;

  /// Called for a vehicle reported earlier that turned out to be another
  /// one seen twice (a misread of its number): it was merged into that
  /// one, which is reported again. A host saving each vehicle deletes it.
  final void Function(PatrolVehicle vehicle)? onVehicleRemoved;

  /// Write the patrol (live text per frame and the vehicles) to
  /// `et_plate_logs/patrol_<time>.json` in the cache. On in debug builds.
  final bool recordSessions;

  /// The camera service (for the preview).
  PlateRecognitionService get service => _service;

  bool _ready = false, _running = false, _disposed = false;
  String? _error;
  PlateReaderErrorCode? _errorCode;
  StreamSubscription<OcrFrame>? _frames;
  DateTime? _started;
  bool _reading = false, _grabbing = false;
  String? _logPicture;
  Future<void>? _pending;
  // Vehicles whose picture is being taken or read, and those that left
  // meanwhile, read only once: reported or dropped when it is done.
  final _checking = <PatrolVehicle>{};
  final _held = <PatrolVehicle>{};
  PatrolVehicle? _focus;
  final List<Map<String, Object?>> _log = [];
  final _traces = <int, List<Map<String, Object?>>>{};

  /// Whether the camera is set up.
  bool get isReady => _ready;

  /// Whether plates are being read.
  bool get isRunning => _running;

  /// Last error, and its kind (e.g. permission denied).
  String? get error => _error;

  /// Kind of [error].
  PlateReaderErrorCode? get errorCode => _errorCode;

  /// Vehicles read so far, newest first.
  List<PatrolVehicle> get vehicles =>
      _tracker.vehicles.reversed.where((v) => !_held.contains(v)).toList();

  /// Plates in view now.
  List<PatrolVehicle> get inView => _tracker.active;

  /// The plate being read now (one at a time), or null.
  PatrolVehicle? get focus =>
      _focus != null && _tracker.active.contains(_focus) ? _focus : null;

  /// Whether the focus plate's photo is being read.
  bool get isReading => _reading;

  /// Whether [v] was read in full (code, region, number).
  bool isRefined(PatrolVehicle v) => v.complete;

  /// Asks for the camera and starts reading.
  Future<void> start() async {
    if (_disposed || _running) return;
    _error = null;
    _errorCode = null;
    try {
      if (!await _requestPermission()) {
        throw PlateReaderException(
          PlateReaderErrorCode.permissionDenied,
          'Camera permission is required to read plates.',
        );
      }
      if (!await _service.isSupported()) {
        throw PlateReaderException(
          PlateReaderErrorCode.unsupportedDevice,
          'This device cannot read plates.',
        );
      }
      if (!_ready) {
        await _service.initialize();
        _frames = _service.frameStream.listen(_onFrame);
        _ready = true;
      }
      await _service.ensureReady();
      await _service.start();
      _started ??= DateTime.now();
      _running = true;
    } catch (e) {
      _error = e is PlateReaderException ? e.message : 'Camera failed: $e';
      _errorCode = e is PlateReaderException ? e.code : null;
    }
    _notify();
  }

  /// Stops reading; reports the vehicles still in view and returns all,
  /// newest first.
  Future<List<PatrolVehicle>> stop() async {
    // A photo being taken or read: let it land on its vehicle first.
    try {
      await _pending?.timeout(const Duration(milliseconds: 2500));
    } catch (_) {}
    if (_running &&
        recordSessions &&
        _logPicture == null &&
        !_tracker.vehicles.any((v) => v.photoPath != null)) {
      // No photo taken: a picture of the scene, so the log has a place to
      // go and shows what the camera saw.
      try {
        _logPicture =
            (await _service.grabFrame().timeout(const Duration(seconds: 1)))
                .path;
      } catch (_) {}
    }
    if (_running) {
      _running = false;
      try {
        await _service.pause();
      } catch (_) {}
    }
    _tracker.finishAll().forEach(_leave);
    _reportMerges();
    _decideHeld();
    await _saveLog();
    _notify();
    return vehicles;
  }

  void _onFrame(OcrFrame frame) {
    if (!_running || _disposed) return;
    final now = DateTime.now();
    if (recordSessions && _log.length < 3000) {
      _log.add({
        't_ms': now.difference(_started ?? now).inMilliseconds,
        'lines': [
          for (final l in frame.lines)
            {'text': l.text, 'box': SessionLog.rect(l.box)},
        ],
      });
    }
    final read = <PatrolVehicle>[];
    final left = _tracker.update(frame.lines, now, readNow: read);
    _reportMerges();
    _chooseFocus(read);
    final f = focus;
    if (f != null && read.contains(f) && _wantsPhoto(f)) {
      _checking.add(f);
      _pending = _readFocus(f, frame.id);
    } else if (!_reading && !_grabbing) {
      // Vehicles that aren't the focus (or not fully in view yet) get a
      // video frame, so each has a picture.
      final bare = read
          .where((v) => v.photoPath == null && !identical(v, f))
          .firstOrNull;
      if (bare != null) {
        _checking.add(bare);
        _pending = _snapshot(bare, frame.id);
      }
    }
    left.forEach(_leave);
    _notify();
  }

  /// One plate at a time: the current focus stays while it is in view and
  /// still being read; otherwise — or when another plate read now is much
  /// closer (1.5× larger) — the largest plate read in full view.
  void _chooseFocus(List<PatrolVehicle> read) {
    final candidates = [
      for (final v in read)
        if (_inFullView(v.box)) v,
    ]..sort((a, b) => b.box.width.compareTo(a.box.width));
    final current = focus;
    if (candidates.isEmpty) {
      if (current == null) _focus = null;
      return;
    }
    final best = candidates.first;
    if (current == null ||
        (!identical(best, current) &&
            (current.complete && current.photos >= 1 ||
                best.box.width > current.box.width * 1.5))) {
      _focus = best;
    }
  }

  static bool _inFullView(NormalizedRect b) =>
      b.left >= 0.03 && b.right <= 0.97 && b.top >= 0.03 && b.bottom <= 0.97;

  /// A (new) full reading is worth it when the plate is clearly closer
  /// (larger) than in its last photo, or not complete yet; up to
  /// [maxPhotos] per vehicle.
  bool _wantsPhoto(PatrolVehicle v) {
    if (_reading || _grabbing || v.photos >= maxPhotos || !_inFullView(v.box)) {
      return false;
    }
    final had = v.photoBox;
    // A snapshot (no full reading yet) doesn't count.
    return v.photos == 0 || had == null || v.box.width > had.width * 1.3;
  }

  /// Photos (full readings) of one vehicle at most.
  static const maxPhotos = 3;

  /// How long a full-resolution still may take before the next video frame
  /// is used instead.
  static const stillTimeout = Duration(milliseconds: 1500);

  /// Photographs the focus plate and reads it in full (as a single scan).
  /// A full-resolution still where available, else a video frame.
  Future<void> _readFocus(PatrolVehicle v, int? frameId) async {
    _reading = true;
    _notify();
    final box = v.box;
    v.photos++;
    final hadPhoto = v.photoPath;
    var kept = false;
    // The full-resolution still takes 0.5–1 s; walking, the plate is at
    // the edge or gone by then. So first the very frame it was read from
    // (fully in view), and the still, already on its way, only when that
    // didn't read it in full.
    final still = _service.captureFrame().timeout(stillTimeout);
    unawaited(still.then((_) {}, onError: (_) {}));
    try {
      if (frameId != null) {
        try {
          kept = await _readPhoto(v, await _service.frameImage(frameId), box);
        } catch (_) {}
      }
      if (!v.complete && !_disposed) {
        CapturedFrame? frame;
        try {
          frame = await still;
        } catch (_) {
          // The still failed or took too long: the next frame, when the
          // exact one wasn't read.
          if (frameId == null) frame = await _service.grabFrame();
        }
        if (frame != null) kept = await _readPhoto(v, frame, box) || kept;
      }
      // Reported again when read in full, or when it had already been
      // reported (it left before its photo was ready) and now has one.
      // Held (left, read once): reported or dropped once checked.
      if (!_held.contains(v) &&
          (kept || (v.photoPath != hadPhoto && _reported(v)))) {
        onVehicle?.call(v);
      }
    } finally {
      _reading = false;
      _checked(v);
      _notify();
    }
  }

  /// Reads [frame] of [v] in full (its plate seen at [box] when the frame
  /// was asked for) and keeps it as its photo when it is the better one.
  /// Returns whether the reading was kept.
  Future<bool> _readPhoto(
      PatrolVehicle v, CapturedFrame frame, NormalizedRect box) async {
    final trace = RefineTrace();
    try {
      final r = await PatrolRefiner(_service)
          .refine(frame.path, v.serial ?? '', box, trace: trace);
      // Where the number was found on the photo, a plate should be around
      // it (a blurred photo where it wasn't found says nothing).
      if (trace.numberText != null) {
        v.outlineChecks++;
        if (trace.outline) v.outlinesFound++;
      }
      final kept = r != null && !_disposed && v.applyFull(r);
      // The photo of the kept full reading, else the closest one.
      if (kept ||
          v.photoBox == null ||
          v.sectionAreas.isEmpty ||
          box.width >= v.photoBox!.width) {
        v.photoPath = frame.path;
        v.photoBox = trace.area ?? box;
        v.sectionAreas = _sectionAreas(trace);
      }
      return kept;
    } catch (e) {
      trace.failure ??= 'error: $e';
      return false;
    } finally {
      (_traces[v.id] ??= []).add(trace.toJson());
    }
  }

  /// [v] has left the view and been reported.
  bool _reported(PatrolVehicle v) =>
      !_tracker.active.contains(v) &&
      !_held.contains(v) &&
      _tracker.vehicles.contains(v);

  /// The picture of the frame a number was read from ([frameId]), else the
  /// next frame.
  Future<CapturedFrame> _frameOf(int? frameId) =>
      frameId == null ? _service.grabFrame() : _service.frameImage(frameId);

  /// [v] has left the view: reported when it is a plate. A plate walked
  /// past is read again and again, and mostly with its region; random
  /// text (a sticker, a sign, a clock, a misread) is glimpsed in a frame
  /// or two with nothing around it. So: read in 3 or more frames, or with
  /// plate evidence — its region read, a plate outline seen around it, or
  /// a national number (`ABC1234`) read twice. A diplomatic number (common
  /// on stickers: `10 8161`) only with the outline. Otherwise dropped
  /// (walks of 2026-10-23: all 10 random detections, no real plate).
  /// While its picture is still being checked, that waits.
  void _leave(PatrolVehicle v) {
    final diplomatic = v.code == PlateServiceType.diplomatic.code;
    final national = v.code == PlateServiceType.national.code;
    final plate = v.outlinesFound > 0 ||
        (!diplomatic &&
            (v.votes >= minVotes ||
                v.regionCode != null ||
                (national && v.votes >= 2)));
    if (plate) {
      onVehicle?.call(v);
    } else if (_checking.contains(v)) {
      _held.add(v);
    } else {
      _tracker.discard(v);
    }
  }

  /// Frames a number must be read in to count as a plate without other
  /// evidence (see [_leave]).
  static const minVotes = 3;

  /// Vehicles merged in the tracker: the host is told those it had been
  /// given that are gone, and given again those whose reading changed.
  void _reportMerges() {
    final m = _tracker.takeMerges();
    for (final v in m.gone) {
      _held.remove(v);
      _checking.remove(v);
      onVehicleRemoved?.call(v);
    }
    for (final v in m.updated) {
      if (_reported(v)) onVehicle?.call(v);
    }
  }

  /// [v]'s picture has been taken and checked.
  void _checked(PatrolVehicle v) {
    _checking.remove(v);
    if (_held.remove(v)) _leave(v);
  }

  /// The patrol ended: held vehicles whose check didn't finish are decided
  /// as unchecked.
  void _decideHeld() {
    _checking.clear();
    for (final v in [..._held]) {
      _held.remove(v);
      _leave(v);
    }
  }

  /// A video frame of [v], which isn't the focus, so every vehicle has a
  /// picture. It isn't read in full.
  Future<void> _snapshot(PatrolVehicle v, int? frameId) async {
    _grabbing = true;
    final box = v.box;
    try {
      final frame = await _frameOf(frameId);
      final attached = v.photoPath == null && !_disposed;
      if (attached) {
        v.photoPath = frame.path;
        v.photoBox = box;
      }
      // Is there a plate around the number at all?
      final bounds =
          await findCaptureBounds(frame.path, PatrolRefiner.seedAround(box));
      v.outlineChecks++;
      if (bounds != null && bounds.isPlate) {
        v.outlinesFound++;
        if (v.photoPath == frame.path) v.photoBox = bounds.area;
      }
      // It left before its picture was ready: report it again with it.
      if (attached && _reported(v) && !_disposed) onVehicle?.call(v);
    } catch (_) {
      // No picture for this one; the number still stands.
    } finally {
      _grabbing = false;
      _checked(v);
    }
  }

  /// The sections found in [t]'s photo, in photo coordinates.
  static Map<String, NormalizedRect> _sectionAreas(RefineTrace t) {
    final seg = t.segmentation, area = t.area;
    if (seg == null || area == null || !seg.found) return const {};
    NormalizedRect at(NormalizedRect r) => NormalizedRect(
          area.left + r.left * area.width,
          area.top + r.top * area.height,
          area.left + r.right * area.width,
          area.top + r.bottom * area.height,
        );
    NormalizedRect? union(List<NormalizedRect> rs) =>
        rs.isEmpty ? null : rs.reduce((a, b) => a.union(b));
    final code = seg.code ?? union(seg.leftDigits) ?? union(seg.leftWord);
    final geez = union(seg.geezStack), latin = union(seg.latinStack);
    return {
      if (code != null) 'code': at(code),
      if (geez != null) 'geezRegion': at(geez),
      if (seg.number != null) 'number': at(seg.number!),
      if (latin != null) 'latinRegion': at(latin),
    };
  }

  Future<void> _saveLog() async {
    if (!recordSessions || _log.isEmpty) return;
    final photo = _tracker.vehicles
            .map((v) => v.photoPath)
            .whereType<String>()
            .firstOrNull ??
        _logPicture;
    if (photo == null) return;
    try {
      final dir = Directory('${File(photo).parent.path}/et_plate_logs')
        ..createSync(recursive: true);
      final start = _started ?? DateTime.now();
      await File('${dir.path}/patrol_${start.millisecondsSinceEpoch}.json')
          .writeAsString(jsonEncode({
        'started': start.toIso8601String(),
        'frames': _log,
        'vehicles': [
          for (final v in _tracker.vehicles)
            {
              'plate': v.plate,
              'embassy': v.embassy,
              'votes': v.votes,
              'outlines': '${v.outlinesFound}/${v.outlineChecks}',
              'reads': v.reads,
              'sightings': v.sightings,
              'check': v.needsCheck,
              'complete': v.complete,
              'fullReads': v.fullReads,
              'firstSeen': v.firstSeen.toIso8601String(),
              'lastSeen': v.lastSeen.toIso8601String(),
              'photo': v.photoPath,
              'box': SessionLog.rect(v.photoBox),
              'refines': _traces[v.id],
            },
        ],
      }));
    } catch (_) {}
  }

  /// Turns the torch on or off.
  Future<bool> setTorch(bool on) => _service.setTorch(on);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // Closed without Finish (close button, back): the vehicles still in
    // view are reported too, so a host saving each one loses none.
    if (_running) {
      _running = false;
      _tracker.finishAll().forEach(_leave);
      _reportMerges();
      _decideHeld();
      unawaited(_saveLog());
    }
    _disposed = true;
    _frames?.cancel();
    unawaited(_service.dispose());
    super.dispose();
  }
}
