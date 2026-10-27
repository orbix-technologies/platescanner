import '../models/ocr_frame.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/ethiopian_region.dart';
import '../parsing/plate_service_type.dart';

/// A vehicle read while patrolling: one plate, seen over several frames.
class PatrolVehicle {
  PatrolVehicle._(this.id, this.firstSeen);

  /// Unique within the patrol.
  final int id;

  /// When the plate first came into view.
  final DateTime firstSeen;

  /// When it was last seen.
  late DateTime lastSeen = firstSeen;

  /// Code, region and number of the winning reading.
  String? code, regionCode, serial;

  /// Diplomatic plates: the embassy number (e.g. `06`).
  String? embassy;

  /// Frames the plate was seen in; of those, how many read a number, and
  /// how many read the winning number.
  int sightings = 0, reads = 0, votes = 0;

  /// The photo of the vehicle: an analysis frame (the visible preview).
  String? photoPath;

  /// The plate's box in [photoPath], normalized.
  NormalizedRect? photoBox;

  /// Where each section was read in [photoPath] (normalized), from the full
  /// reading kept: `code`, `geezRegion`, `number`, `latinRegion`.
  Map<String, NormalizedRect> sectionAreas = const {};

  /// Where the plate was last seen in the frame (normalized).
  NormalizedRect box = const NormalizedRect(0, 0, 0, 0);

  final Map<String, int> _reads = {};
  final Map<String, PlateCandidate> _byKey = {};

  /// The plate as text, e.g. `2-AA-B05475`.
  String get plate => [
        if (code != null) code,
        if (regionCode != null) regionCode,
        serial ?? '?',
      ].join('-');

  /// Share of the frames that read a number and agree with the winner.
  double get confidence => reads == 0 ? 0 : votes / reads;

  /// The number is uncertain: read only once, or the frames disagree.
  bool get needsCheck => votes < 2 || confidence < 0.5;

  /// Category of [code].
  PlateServiceType? get serviceType => PlateServiceType.fromCode(code);

  /// As a [PlateRecord] for storage or the host app.
  PlateRecord toRecord() => PlateRecord(
        id: 'patrol-$id-${firstSeen.microsecondsSinceEpoch}',
        code: code ?? '',
        regionCode: regionCode,
        serial: serial ?? '',
        layout: layout,
        rawText: plate,
        confidence: confidence,
        capturedAt: firstSeen,
        imagePath: photoPath,
        plateArea: photoBox,
        sectionAreas: sectionAreas,
        status: noPlateSeen ? 'check' : 'confirmed',
      );

  /// A number a plate can carry: 5 digits with an optional series letter,
  /// 6–7 digits, the new national `ABC1234`, or 4 digits on a diplomatic
  /// plate. Other text in view (clocks, phone numbers on stickers) doesn't
  /// make a vehicle.
  static bool _plausible(String serial, String? code) =>
      RegExp(r'^(\d{5,7}|[A-Z]\d{5}|[A-Z]{3}\d{4})$').hasMatch(serial) ||
      (code == 'CD' && RegExp(r'^\d{4}$').hasMatch(serial));

  /// Photos taken of this vehicle so far.
  int photos = 0;

  /// Pictures of it (photos and video frames) searched for a plate outline
  /// around the number, and in how many one was found.
  int outlineChecks = 0, outlinesFound = 0;

  /// Its pictures were searched and none showed a plate around the number:
  /// likely text that isn't on a plate (a screen, a sign, paper).
  bool get noPlateSeen => outlineChecks > 0 && outlinesFound == 0;

  /// Full structural readings of its photos (code, region, number, as a
  /// single scan reads them), and the best one that agrees with the live
  /// number.
  int fullReads = 0;
  PlateCandidate? _full;

  /// One or two rows, from the full reading (one row until there is one).
  PlateLayout get layout => _full?.layout ?? _liveLayout;
  PlateLayout _liveLayout = PlateLayout.singleRow;

  /// The plate was read in full — code, region (where its kind has one)
  /// and number — and that reading agrees with the live number.
  bool get complete =>
      _full != null &&
      _full!.isValid &&
      serial != null &&
      lookAlike(_full!.serial!) == lookAlike(serial!);

  /// Takes a full structural reading [r] of a photo. It is kept when its
  /// number agrees with the live one (look-alikes equal) — or, when the
  /// live number is uncertain, when it is complete — and when it is better
  /// than the one kept so far (valid over not, more parts read).
  /// Returns whether it was kept.
  bool applyFull(PlateCandidate r) {
    fullReads++;
    if (r.serial == null) return false;
    var agrees = serial != null && lookAlike(r.serial!) == lookAlike(serial!);
    // The series letter misread in the number crop (`170677` for
    // `C70677`), the rest the same: its code and region stand, with the
    // number most frames read.
    final s = serial;
    if (!agrees &&
        s != null &&
        RegExp(r'^[A-Z]\d{5}$').hasMatch(s) &&
        r.serial!.length == s.length &&
        r.serial!.substring(1) == s.substring(1)) {
      r = PlateCandidate(
        code: r.code,
        regionCode: r.regionCode,
        serial: s,
        layout: r.layout,
        rawText: r.rawText,
        confidence: r.confidence,
        issues: r.issues,
      );
      agrees = true;
    }
    if (!agrees && !(needsCheck && r.isValid)) return false;
    int score(PlateCandidate c) =>
        (c.isValid ? 4 : 0) +
        (c.code != null ? 2 : 0) +
        (c.regionCode != null ? 1 : 0);
    if (_full != null && score(_full!) >= score(r)) return false;
    _full = r;
    _recount();
    return true;
  }

  /// Adds one sighting; true when it read a plausible number.
  bool _add(PlateCandidate c, NormalizedRect at, DateTime now,
      [String? embassyRead]) {
    sightings++;
    if (embassyRead != null && c.code == 'CD') embassy = embassyRead;
    lastSeen = now;
    box = at;
    if (c.serial == null || !_plausible(c.serial!, c.code)) return false;
    reads++;
    final key = c.key;
    _reads[key] = (_reads[key] ?? 0) + 1;
    _byKey[key] = c;
    _recount();
    return true;
  }

  /// Takes in [other], the same vehicle seen as a separate one (a letter
  /// misread as a digit in some frames, its other plate).
  void _absorb(PatrolVehicle other) {
    sightings += other.sightings;
    reads += other.reads;
    if (other.lastSeen.isAfter(lastSeen)) lastSeen = other.lastSeen;
    // Keep the photo that was read in full, else the closer one (the
    // larger plate).
    final otherRead = other.sectionAreas.isNotEmpty,
        read = sectionAreas.isNotEmpty;
    if (other.photoPath != null &&
        (photoPath == null ||
            (otherRead && !read) ||
            (otherRead == read &&
                (other.photoBox?.width ?? 0) > (photoBox?.width ?? 0)))) {
      photoPath = other.photoPath;
      photoBox = other.photoBox;
      sectionAreas = other.sectionAreas;
    }
    photos += other.photos;
    outlineChecks += other.outlineChecks;
    outlinesFound += other.outlinesFound;
    embassy ??= other.embassy;
    other._reads.forEach((k, n) {
      _reads[k] = (_reads[k] ?? 0) + n;
      _byKey[k] ??= other._byKey[k]!;
    });
    fullReads += other.fullReads;
    if (other._full != null &&
        (_full == null || (other._full!.isValid && !_full!.isValid))) {
      _full = other._full;
    }
    _recount();
  }

  /// The winner: the number most frames agree on, counting look-alike reads
  /// together (`B08468` / `808468`); shown in its most complete form — with
  /// the series letter when one was read, then the reading that also has
  /// the code and region.
  void _recount() {
    if (_reads.isEmpty) {
      // Nothing read live yet: the full reading is all there is.
      final f = _full;
      if (f != null && f.isValid) {
        code = f.code;
        regionCode = f.regionCode;
        serial = f.serial;
      }
      return;
    }
    final groups = <String, int>{};
    _reads.forEach((k, n) {
      final g = lookAlike(_byKey[k]!.serial!);
      groups[g] = (groups[g] ?? 0) + n;
    });
    final group =
        groups.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final letter = RegExp(r'^[A-Z]\d{5}$');
    String? best;
    var bestScore = -1;
    _reads.forEach((k, n) {
      final cand = _byKey[k]!;
      if (lookAlike(cand.serial!) != group) return;
      final score = (letter.hasMatch(cand.serial!) ? 1000 : 0) +
          n * 10 +
          (cand.isValid ? 5 : 0) +
          (cand.code != null ? 1 : 0) +
          (cand.regionCode != null ? 1 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = k;
      }
    });
    final w = _byKey[best]!;
    serial = w.serial;
    votes = groups[group]!;
    // Code and region voted on their own: live text reads them in a few
    // frames only ("AA" a third of the time), so the reading most often
    // seen whole would mostly be the number alone.
    String? most(String? Function(PlateCandidate) part) {
      final counts = <String, int>{};
      _reads.forEach((k, n) {
        final cand = _byKey[k]!;
        final v = part(cand);
        if (v == null || lookAlike(cand.serial!) != group) return;
        counts[v] = (counts[v] ?? 0) + n;
      });
      return counts.isEmpty
          ? null
          : counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    }

    code = most((c) => c.code);
    regionCode = most((c) => c.regionCode);
    _liveLayout = most((c) => c.regionCode == null ? null : c.layout.name) ==
            PlateLayout.twoRow.name
        ? PlateLayout.twoRow
        : PlateLayout.singleRow;
    // A full structural reading of the same number shows it completely
    // (code and region the live text rarely reads).
    final f = _full;
    if (f != null && f.serial != null && lookAlike(f.serial!) == group) {
      code = f.code ?? code;
      regionCode = f.regionCode ?? regionCode;
      if (f.isValid) serial = f.serial;
    }
  }

  /// [serial] with letters mapped to the digits they're mistaken for (and
  /// back), so misreads of one plate compare equal.
  static String lookAlike(String serial) =>
      serial.toUpperCase().split('').map((c) => _lookAlike[c] ?? c).join();

  static const _lookAlike = {
    'B': '8', 'O': '0', 'D': '0', 'Q': '0', 'C': '0', 'U': '0', //
    'I': '1', 'L': '1', 'J': '1', 'S': '5', 'Z': '2', 'G': '6', 'A': '4',
  };

  @override
  String toString() =>
      'PatrolVehicle#$id($plate, $votes/$reads${needsCheck ? ', check' : ''})';
}

/// Follows plates across the frames of a patrol: each plate in view is
/// matched to the vehicle seen at about the same place (or with the same
/// number) in the previous frames, its readings are voted on, and the
/// vehicle is reported once, after it has left the view.
class PatrolTracker {
  /// Creates a tracker.
  PatrolTracker({
    this.parser = const EthiopianPlateParser(requireRegion: false),
    this.lostAfter = const Duration(milliseconds: 900),
    this.duplicateWindow = const Duration(seconds: 90),
    this.nearWindow = const Duration(seconds: 4),
  });

  /// Reads each plate's lines.
  final EthiopianPlateParser parser;

  /// A vehicle not seen for this long has left the view.
  final Duration lostAfter;

  /// A plate read again within this time (its other plate, or walking back)
  /// is the same vehicle, not a new one.
  final Duration duplicateWindow;

  /// A number one character off a vehicle that left this recently is a
  /// misread of it.
  final Duration nearWindow;

  int _nextId = 1;
  final List<PatrolVehicle> _active = [];
  final List<PatrolVehicle> _done = [];

  /// Vehicles in view now.
  List<PatrolVehicle> get active => List.unmodifiable(_active);

  /// Vehicles reported so far, oldest first.
  List<PatrolVehicle> get vehicles => List.unmodifiable(_done);

  static final _serialLike = RegExp(r'[0-9OQDISBZG]{4,}');
  static final _digits = RegExp(r'\d');
  static final _national = RegExp(r'[A-Z]{3}[0-9OQDGC]{4}');

  /// Diplomatic plate as live text reads it: the embassy number, the dot
  /// between, then the four-digit number (`63-0123`, `06 0123`).
  static final _diplomatic = RegExp(
      r'^\W*(\d{2,3})\s*[-·.•:]?\s+?(\d{4})\W*$|^\W*(\d{2,3})[-·.•:](\d{4})\W*$');

  /// Feeds one frame. Returns the vehicles that left the view in it
  /// (reported now), and [newcomers] gets those first seen with a number.
  List<PatrolVehicle> update(
    List<OcrLine> lines,
    DateTime now, {
    List<PatrolVehicle>? newcomers,
    List<PatrolVehicle>? readNow,
  }) {
    // Text outside the visible preview (the camera frame is wider than
    // the screen): the user can't see it and photos don't contain it.
    final plates = platesIn([
      for (final l in lines)
        if (l.box.centerX >= 0 &&
            l.box.centerX <= 1 &&
            l.box.centerY >= 0 &&
            l.box.centerY <= 1)
          l,
    ]);
    final unmatched = [..._active];
    for (final (c, box, embassy) in plates) {
      final v = _match(c, box, unmatched, embassy);
      if (v != null) {
        unmatched.remove(v);
        final hadNumber = v.serial != null;
        if (v._add(c, box, now, embassy)) readNow?.add(v);
        if (!hadNumber && v.serial != null) newcomers?.add(v);
      } else {
        final nv = PatrolVehicle._(_nextId++, now);
        if (nv._add(c, box, now, embassy)) readNow?.add(nv);
        _active.add(nv);
        if (nv.serial != null) newcomers?.add(nv);
      }
    }
    final left = <PatrolVehicle>[];
    for (final v in [..._active]) {
      if (now.difference(v.lastSeen) < lostAfter) continue;
      _active.remove(v);
      final reported = _finish(v);
      if (reported != null) left.add(reported);
    }
    return left;
  }

  final _mergedAway = <PatrolVehicle>{};
  final _updated = <PatrolVehicle>{};

  /// Since the last call: reported vehicles merged into another (the same
  /// plate seen as two, e.g. a misread), and the vehicles they, or a
  /// vehicle leaving now, were merged into (their reading changed).
  ({List<PatrolVehicle> gone, List<PatrolVehicle> updated}) takeMerges() {
    final out = (
      gone: _mergedAway.toList(),
      updated: _updated.where((v) => !_mergedAway.contains(v)).toList(),
    );
    _mergedAway.clear();
    _updated.clear();
    return out;
  }

  /// Forgets [v], a reported vehicle that turned out not to be one.
  void discard(PatrolVehicle v) => _done.remove(v);

  /// Reports every vehicle still in view (the patrol ended).
  List<PatrolVehicle> finishAll() {
    final out = <PatrolVehicle>[];
    for (final v in [..._active]) {
      final r = _finish(v);
      if (r != null) out.add(r);
    }
    _active.clear();
    return out;
  }

  /// A vehicle that left: dropped when no number was read, merged into an
  /// earlier one with the same number, else reported. Returns the vehicle
  /// to report, or null.
  PatrolVehicle? _finish(PatrolVehicle v) {
    if (v.serial == null) return null;
    for (final d in _done.reversed) {
      final gap = v.firstSeen.difference(d.lastSeen);
      if (gap > duplicateWindow) break;
      if (d.embassy != v.embassy) continue;
      // Same number (look-alikes equal): its other plate, or seen again.
      // One character apart: a misread of the plate just passed.
      if (_sameNumber(d.serial, v.serial) ||
          (gap < nearWindow && _oneApart(d.serial, v.serial))) {
        _merge(d, v);
        return null;
      }
      // Read once, close to a well-read plate just passed: a misread of it.
      if (gap < nearWindow &&
          (v.votes <= 1 || d.votes <= 1) &&
          (v.votes >= 3 || d.votes >= 3) &&
          _similar(d.serial, v.serial)) {
        _merge(d, v);
        return null;
      }
    }
    _done.add(v);
    return v;
  }

  /// [v] into [d]. Pooling the reads can change [d]'s winning number, so
  /// finished vehicles that now share a number are merged too, until none
  /// do (the one reported first is kept).
  void _merge(PatrolVehicle d, PatrolVehicle v) {
    d._absorb(v);
    _updated.add(d);
    var merged = true;
    while (merged) {
      merged = false;
      for (final a in _done) {
        for (final b in _done) {
          if (identical(a, b) || a.id > b.id || a.embassy != b.embassy) {
            continue;
          }
          final apart = b.firstSeen.isAfter(a.lastSeen)
              ? b.firstSeen.difference(a.lastSeen)
              : Duration.zero;
          if (apart <= duplicateWindow && _sameNumber(a.serial, b.serial)) {
            a._absorb(b);
            _done.remove(b);
            _mergedAway.add(b);
            _updated.add(a);
            merged = true;
            break;
          }
        }
        if (merged) break;
      }
    }
  }

  PatrolVehicle? _match(PlateCandidate c, NormalizedRect box,
      List<PatrolVehicle> pool, String? embassy) {
    PatrolVehicle? best;
    var bestScore = 0.0;
    for (final v in pool) {
      // Two embassies' plates can share the number; a diplomatic read only
      // joins a diplomatic vehicle (or one with no number yet).
      if (embassy != null && v.embassy != null && embassy != v.embassy) {
        continue;
      }
      final dip = c.code == PlateServiceType.diplomatic.code;
      if (v.serial != null &&
          dip != (v.code == PlateServiceType.diplomatic.code)) {
        continue;
      }
      var score = 0.0;
      if (c.serial != null && _sameNumber(v.serial, c.serial)) score += 2;
      final dx = (v.box.centerX - box.centerX).abs();
      final dy = (v.box.centerY - box.centerY).abs();
      final w = v.box.width > box.width ? v.box.width : box.width;
      final h = v.box.height > box.height ? v.box.height : box.height;
      // Moving past: the plate slides sideways a plate width or two between
      // frames, but stays at about the same height.
      if (dy < h * 1.5 && dx < w * 2.5) score += 1 - dx / (w * 2.5);
      if (score > bestScore) {
        bestScore = score;
        best = v;
      }
    }
    return best;
  }

  static bool _sameNumber(String? a, String? b) {
    if (a == null || b == null) return false;
    final x = PatrolVehicle.lookAlike(a), y = PatrolVehicle.lookAlike(b);
    return x == y && x.length >= 4;
  }

  /// All but two characters in common, in order (look-alikes equal), on
  /// numbers of five or more.
  static bool _similar(String? a, String? b) {
    if (a == null || b == null) return false;
    final x = PatrolVehicle.lookAlike(a), y = PatrolVehicle.lookAlike(b);
    if (x.length < 5 || y.length < 5) return false;
    // Longest common subsequence.
    final m = List.generate(x.length + 1, (_) => List.filled(y.length + 1, 0));
    for (var i = 1; i <= x.length; i++) {
      for (var j = 1; j <= y.length; j++) {
        m[i][j] = x[i - 1] == y[j - 1]
            ? m[i - 1][j - 1] + 1
            : (m[i - 1][j] > m[i][j - 1] ? m[i - 1][j] : m[i][j - 1]);
      }
    }
    final longest = x.length > y.length ? x.length : y.length;
    return m[x.length][y.length] >= longest - 2;
  }

  /// One character missing, extra or different (look-alikes equal), on
  /// numbers of five or more.
  static bool _oneApart(String? a, String? b) {
    if (a == null || b == null) return false;
    final x = PatrolVehicle.lookAlike(a), y = PatrolVehicle.lookAlike(b);
    if (x.length < 5 || y.length < 5 || (x.length - y.length).abs() > 1) {
      return false;
    }
    if (x.length == y.length) {
      var diff = 0;
      for (var i = 0; i < x.length; i++) {
        if (x[i] != y[i]) diff++;
      }
      return diff == 1;
    }
    final (long, short) = x.length > y.length ? (x, y) : (y, x);
    for (var i = 0; i < long.length; i++) {
      if (long.substring(0, i) + long.substring(i + 1) == short) return true;
    }
    return false;
  }

  /// Phone numbers and web text printed on vehicles (spare-wheel covers,
  /// stickers, screens, signs): a word in small letters, a `+`, `@`, `:`,
  /// `www` / `.com`, a mobile number (`09…`, `07…`), or three or more
  /// groups of digits — never on a plate.
  static bool _notAPlate(String text) {
    // Plates carry capital letters only: a word in small letters is
    // writing (a screen, a sign, a sticker).
    if (RegExp(r'[a-z]{3,}').hasMatch(text)) return true;
    final t = text.toLowerCase();
    if (t.contains('+') || t.contains('@') || t.contains('www')) return true;
    // Times, addresses, ports (`10:45`, `10.42.0.165:34585`).
    if (t.contains(':')) return true;
    // Ethiopian mobile numbers (`0930103…`, `0711…`) on stickers.
    if (RegExp(r'(^|\D)0[79]\d{5,}').hasMatch(t.replaceAll(' ', ''))) {
      return true;
    }
    if (RegExp(r'\.(com|et|net|org)').hasMatch(t)) return true;
    return RegExp(r'\d+').allMatches(t).length >= 3;
  }

  /// A two-row plate's top row as live text reads it: one line, the
  /// circle (`O`, `9`, `©` or its digit), the Ge'ez pair in small letters
  /// (ሕሕ reads `hh`), then the region in capitals (`OhhAA`, `9h hA A`).
  /// The region is the trailing capitals, when they are a region code. The
  /// Ge'ez part is never taken for a region (`hh` is not Harari's `HR`).
  /// The circle's digit reads as anything (`9`, `7`, `1`, `O` for a 2):
  /// the code is left to the full reading.
  static ({String region, OcrLine line})? _topRow(List<OcrLine> lines) {
    for (final l in lines) {
      final t = l.text.replaceAll(RegExp(r'[\s.·•,]'), '');
      final m = RegExp(r'([A-Z]{2})\W*$').firstMatch(t);
      if (m == null) continue;
      // Not a word: the capitals follow other marks (circle, Ge'ez).
      if (m.start > 0 && RegExp(r'[A-Z]$').hasMatch(t.substring(0, m.start))) {
        continue;
      }
      final region = EthiopianRegion.fromCode(m.group(1));
      if (region == null) continue;
      return (region: region.code, line: l);
    }
    return null;
  }

  /// The circled code read as a letter and joined to the number
  /// (`O30142`, `G30138`): series letters are A, B, C…, never O, G or Q, so
  /// that letter is dropped and the five digits kept.
  static PlateCandidate _withoutCircle(PlateCandidate c) {
    final s = c.serial;
    if (s == null || !RegExp(r'^[OGQ]\d{5}$').hasMatch(s)) return c;
    return PlateCandidate(
      code: c.code,
      regionCode: c.regionCode,
      serial: s.substring(1),
      layout: c.layout,
      rawText: c.rawText,
      confidence: c.confidence,
      issues: c.issues,
      boundingBox: c.boundingBox,
    );
  }

  /// The plates in one frame's lines: each line carrying a number (or a new
  /// national number) with the lines beside it on its band, read together.
  ///
  /// Each comes with the embassy number on diplomatic plates.
  List<(PlateCandidate, NormalizedRect, String?)> platesIn(
      List<OcrLine> lines) {
    final out = <(PlateCandidate, NormalizedRect, String?)>[];
    final used = <OcrLine>{};
    final anchors = lines.where((l) {
      if (_notAPlate(l.text)) return false;
      final t = l.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final run = _serialLike.firstMatch(t)?.group(0);
      return (run != null && _digits.allMatches(run).length >= 4) ||
          _national.hasMatch(t);
    }).toList()
      ..sort((a, b) => b.box.height.compareTo(a.box.height));
    for (final a in anchors) {
      if (used.contains(a)) continue;
      final h = a.box.height;
      final band = [
        for (final l in lines)
          if (!used.contains(l) &&
              (identical(l, a) || !_notAPlate(l.text)) &&
              (l.box.centerY - a.box.centerY).abs() <= h * 0.8 &&
              l.box.right >= a.box.left - 3 * h &&
              l.box.left <= a.box.right + 2 * h)
            l,
      ];
      used.addAll(band);
      var box = band.first.box;
      for (final l in band.skip(1)) {
        box = box.union(l.box);
      }
      // A national number starting with O / G / Q is the circled code read
      // as a letter in front of an old plate's number (`ONB2540`).
      var national = parser.readNationalSerial(a.text);
      if (national != null && 'OGQ'.contains(national[0])) national = null;
      final dip = _diplomatic.firstMatch(a.text.trim());
      if (dip != null) {
        out.add((
          PlateCandidate(
            code: PlateServiceType.diplomatic.code,
            regionCode: null,
            serial: dip.group(2) ?? dip.group(4),
            layout: PlateLayout.singleRow,
            rawText: a.text,
            confidence: a.confidence ?? 0.8,
            issues: const [],
          ),
          box,
          dip.group(1) ?? dip.group(3),
        ));
        continue;
      }
      var c = national != null
          ? PlateCandidate(
              code: PlateServiceType.national.code,
              regionCode: null,
              serial: national,
              layout: PlateLayout.singleRow,
              rawText: a.text,
              confidence: a.confidence ?? 0.8,
              issues: const [],
            )
          : parser.parse(band);
      // The region is beside the number on one-row plates, on the row
      // above it on two-row ones (circle, Ge'ez, chip, "AA"), so close
      // that it may be in the band: smaller text beside or just above,
      // within the number's width, with no number of its own (that would
      // be another plate above). Read by its layout, it wins over the
      // parser's guess (which can take the Ge'ez `hh` for Harari).
      if (national == null) {
        final near = [
          for (final l in band)
            if (!identical(l, a)) l,
          for (final l in lines)
            if (!used.contains(l) &&
                !_notAPlate(l.text) &&
                l.box.height <= h * 0.85 &&
                l.box.bottom <= a.box.top + h * 0.5 &&
                l.box.centerY >= a.box.top - h * 1.6 &&
                l.box.left >= a.box.left - h * 0.8 &&
                l.box.right <= a.box.right + h * 0.8 &&
                !RegExp(r'\d{4}').hasMatch(l.text))
              l,
        ];
        final top = _topRow(near);
        if (top != null) {
          final code = c.code;
          final twoRow = top.line.box.centerY < a.box.top;
          c = PlateCandidate(
            code: code,
            regionCode: top.region,
            serial: c.serial,
            layout: twoRow ? PlateLayout.twoRow : c.layout,
            rawText: c.rawText,
            confidence: c.confidence,
            issues: parser.validate(
                code: code, regionCode: top.region, serial: c.serial),
          );
        }
      }
      out.add((_withoutCircle(c), box, null));
    }
    return out;
  }
}
