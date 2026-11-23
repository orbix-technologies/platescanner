import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/ocr_frame.dart';
import 'plate_bounds_finder.dart';
import 'plate_segmenter.dart';

/// Height the plate area is scaled to before segmentation.
const segmentationHeight = 160;

/// Controlled prep variants for multi-read consensus (same still, different
/// geometry / contrast). Deskew itself lives inside [PlateSegmenter].
enum SegmentPrep {
  /// Default crop → 160 px → grayscale / ink.
  primary,

  /// Contrast-stretched luminance before segmentation.
  contrast,

  /// Slightly taller crop (more vertical margin) before resize.
  padVertical,
}

/// JPEG/PNG bytes for one still, loaded once and reused across prep passes
/// so each segment/gray call skips another disk read.
class PreparedStill {
  PreparedStill._(this.path, this.bytes);

  /// Original file path (logging / native OCR).
  final String path;

  /// File bytes (decoded per isolate call, not re-read from disk).
  final Uint8List bytes;

  /// Reads [path] once. Null when missing or empty.
  static Future<PreparedStill?> load(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return PreparedStill._(path, bytes);
  }

  /// Sync load for tests / tools.
  static PreparedStill? loadSync(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.isEmpty) return null;
    return PreparedStill._(path, bytes);
  }
}

/// Segments [area] (normalized) of the JPEG still at [path], off the UI
/// isolate. Boxes in the result are normalized to [area]. Returns null when
/// the image can't be read. Pass [still] to skip re-reading the file.
Future<PlateSegmentation?> segmentCapture(
  String path,
  NormalizedRect area, {
  SegmentPrep prep = SegmentPrep.primary,
  PreparedStill? still,
}) async {
  final bytes = still?.bytes ??
      (File(path).existsSync() ? File(path).readAsBytesSync() : null);
  if (bytes == null || bytes.isEmpty) return null;
  final l = area.left, t = area.top, r = area.right, b = area.bottom;
  final p = prep;
  final copy = Uint8List.fromList(bytes);
  return Isolate.run(
      () => segmentCaptureFromBytes(copy, NormalizedRect(l, t, r, b), prep: p));
}

/// Synchronous body of [segmentCapture] (tests, tools).
PlateSegmentation? segmentCaptureSync(
  String path,
  NormalizedRect area, {
  SegmentPrep prep = SegmentPrep.primary,
  PreparedStill? still,
}) {
  final bytes = still?.bytes ??
      (File(path).existsSync() ? File(path).readAsBytesSync() : null);
  if (bytes == null || bytes.isEmpty) return null;
  return segmentCaptureFromBytes(bytes, area, prep: prep);
}

/// Segments from already-loaded image [bytes] (one decode per call).
PlateSegmentation? segmentCaptureFromBytes(
  Uint8List bytes,
  NormalizedRect area, {
  SegmentPrep prep = SegmentPrep.primary,
}) {
  final photo = img.decodeImage(bytes);
  if (photo == null) return null;
  final first = _segmentArea(photo, area, prep: prep);
  if (first == null || !first.found) return first;
  // A shape cut by the crop's side with its section missing (the circle
  // when the plate's side was taken at the ring, the region letters at
  // the other end): read again with the area wider on that side, kept
  // when it finds more of the plate.
  final cutLeft = first.code == null && _cutAt(first, left: true);
  final cutRight = first.latinStack.length < 2 && _cutAt(first, left: false);
  if (!cutLeft && !cutRight) return first;
  final m = area.width * 0.15;
  final wider = NormalizedRect(
    cutLeft ? (area.left - m).clamp(0.0, 1.0) : area.left,
    area.top,
    cutRight ? (area.right + m).clamp(0.0, 1.0) : area.right,
    area.bottom,
  );
  final again = _segmentArea(photo, wider, prep: prep);
  // Kept when it finds the missing part and loses none (a cut piece of the
  // ring can pass for digits left of the number, so scores may tie).
  bool more(int a, int b) => a >= b;
  final better = again != null &&
      again.found &&
      more(again.numberChars.length, first.numberChars.length) &&
      more(again.geezStack.length, first.geezStack.length) &&
      ((cutLeft && again.code != null) ||
          (cutRight && again.latinStack.length == 2));
  if (!better) return first;
  return _relative(again, wider, area);
}

/// Grayscale working image of [area] on [path] after the same resize used
/// for segmentation (for glyph classification). Null when unreadable.
GrayImage? plateGraySync(
  String path,
  NormalizedRect area, {
  SegmentPrep prep = SegmentPrep.primary,
  PreparedStill? still,
}) {
  final bytes = still?.bytes ??
      (File(path).existsSync() ? File(path).readAsBytesSync() : null);
  if (bytes == null || bytes.isEmpty) return null;
  final photo = img.decodeImage(bytes);
  if (photo == null) return null;
  return _plateGray(photo, area, prep: prep);
}

/// Whether a shape of [s] touches the crop's left (or right) side.
bool _cutAt(PlateSegmentation s, {required bool left}) {
  for (final c in s.columns) {
    final b = c.box;
    if (left ? b.left <= 1 : b.right >= _widthOf(s) - 1) return true;
  }
  return false;
}

/// Width in pixels of the image [s] was segmented on.
int _widthOf(PlateSegmentation s) {
  final note = s.notes
      .firstWhere((n) => n.startsWith('image='), orElse: () => 'image=0x0');
  return int.tryParse(note.substring(6).split('x').first) ?? 0;
}

/// [s] (boxes normalized to [from]) with its boxes normalized to [to].
PlateSegmentation _relative(
    PlateSegmentation s, NormalizedRect from, NormalizedRect to) {
  NormalizedRect m(NormalizedRect r) {
    double x(double v) => (from.left + v * from.width - to.left) / to.width;
    double y(double v) => (from.top + v * from.height - to.top) / to.height;
    return NormalizedRect(x(r.left), y(r.top), x(r.right), y(r.bottom));
  }

  NormalizedRect? one(NormalizedRect? r) => r == null ? null : m(r);
  List<NormalizedRect> all(List<NormalizedRect> rs) =>
      [for (final r in rs) m(r)];
  return PlateSegmentation(
    number: one(s.number),
    numberChars: all(s.numberChars),
    code: one(s.code),
    codeInner: one(s.codeInner),
    geezStack: all(s.geezStack),
    latinStack: all(s.latinStack),
    leftDigits: all(s.leftDigits),
    leftWord: all(s.leftWord),
    latinSideBySide: s.latinSideBySide,
    twoRow: s.twoRow,
    columns: s.columns,
    notes: [...s.notes, 'widened'],
  );
}

/// [area] of [photo] as the grayscale working image used for segmentation.
GrayImage? _plateGray(
  img.Image photo,
  NormalizedRect area, {
  SegmentPrep prep = SegmentPrep.primary,
}) {
  var use = area;
  if (prep == SegmentPrep.padVertical) {
    final my = area.height * 0.06;
    use = NormalizedRect(
      area.left,
      (area.top - my).clamp(0.0, 1.0),
      area.right,
      (area.bottom + my).clamp(0.0, 1.0),
    );
  }
  final x = (use.left * photo.width).round().clamp(0, photo.width - 1);
  final y = (use.top * photo.height).round().clamp(0, photo.height - 1);
  final w = (use.width * photo.width).round().clamp(1, photo.width - x);
  final h = (use.height * photo.height).round().clamp(1, photo.height - y);
  if (w < 10 || h < 10) return null;
  final crop = img.copyCrop(photo, x: x, y: y, width: w, height: h);
  final plate = img.copyResize(
    crop,
    height: segmentationHeight,
    interpolation: img.Interpolation.average,
  );
  final gray = img.grayscale(img.Image.from(plate));
  var bytes = gray.getBytes(order: img.ChannelOrder.red);
  if (prep == SegmentPrep.contrast) {
    bytes = _contrastStretch(bytes);
  }
  return GrayImage(gray.width, gray.height, bytes);
}

Uint8List _contrastStretch(Uint8List src) {
  var lo = 255, hi = 0;
  for (final v in src) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  if (hi <= lo) return Uint8List.fromList(src);
  final out = Uint8List(src.length);
  final span = hi - lo;
  for (var i = 0; i < src.length; i++) {
    out[i] = ((src[i] - lo) * 255 / span).round().clamp(0, 255);
  }
  return out;
}

/// [area] of [photo] segmented: by brightness and by the darkest channel,
/// keeping the one that finds more of the plate. Brightness suits most
/// plates; red characters (taxi plates) are about as bright as the plate
/// and show only in the darkest channel.
PlateSegmentation? _segmentArea(
  img.Image photo,
  NormalizedRect area, {
  SegmentPrep prep = SegmentPrep.primary,
}) {
  final brightness = _plateGray(photo, area, prep: prep);
  if (brightness == null) return null;
  // Rebuild colour crop for inkImage (darkest channel) on the same geometry.
  var use = area;
  if (prep == SegmentPrep.padVertical) {
    final my = area.height * 0.06;
    use = NormalizedRect(
      area.left,
      (area.top - my).clamp(0.0, 1.0),
      area.right,
      (area.bottom + my).clamp(0.0, 1.0),
    );
  }
  final x = (use.left * photo.width).round().clamp(0, photo.width - 1);
  final y = (use.top * photo.height).round().clamp(0, photo.height - 1);
  final w = (use.width * photo.width).round().clamp(1, photo.width - x);
  final h = (use.height * photo.height).round().clamp(1, photo.height - y);
  final crop = img.copyCrop(photo, x: x, y: y, width: w, height: h);
  final plate = img.copyResize(
    crop,
    height: brightness.height,
    interpolation: img.Interpolation.average,
  );
  final byBrightness = PlateSegmenter().segment(brightness);
  // Only when brightness misses two parts of the plate or more (red
  // characters seen in pieces) — and not on a plate with a word left of
  // its number (the national plate's ኢት/ETH, special plates): those have
  // no region, and the darkest channel can find one that isn't there.
  if (byBrightness.leftWord.isNotEmpty ||
      PlateSegmenter.score(byBrightness) >= 10 + 4 + 2 + 2) {
    return byBrightness;
  }
  var ink = inkImage(plate);
  if (prep == SegmentPrep.contrast) {
    ink = GrayImage(ink.width, ink.height, _contrastStretch(ink.pixels));
  }
  final byInk = PlateSegmenter().segment(ink);
  return PlateSegmenter.score(byInk) > PlateSegmenter.score(byBrightness)
      ? byInk
      : byBrightness;
}

/// [im] for segmentation: each pixel's darkest colour channel, not its
/// brightness. The plate is white in every channel, while ink of any colour
/// is dark in at least one (red in green and blue, blue in red, green in
/// red and blue): red characters, about as bright as the plate, stand out
/// as much as black ones (old red taxi plates were all but invisible).
GrayImage inkImage(img.Image im) {
  final out = Uint8List(im.width * im.height);
  var i = 0;
  for (final p in im) {
    final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
    out[i++] = r < g ? (r < b ? r : b) : (g < b ? g : b);
  }
  return GrayImage(im.width, im.height, out);
}

/// Snaps [seed] (normalized) to the plate's outline on the JPEG still at
/// [path], off the UI isolate (step 1b); [fallback] is tried when no plate
/// is found near the seed. Returns null when the image can't be read or no
/// plate is found.
Future<NormalizedRect?> snapCaptureArea(
  String path,
  NormalizedRect seed, {
  NormalizedRect? fallback,
}) async {
  if (!File(path).existsSync()) return null;
  NormalizedRect copy(NormalizedRect r) =>
      NormalizedRect(r.left, r.top, r.right, r.bottom);
  final s = copy(seed), f = fallback == null ? null : copy(fallback);
  return Isolate.run(() => snapCaptureAreaSync(path, s, fallback: f));
}

/// Synchronous body of [snapCaptureArea] (tests, tools).
NormalizedRect? snapCaptureAreaSync(
  String path,
  NormalizedRect seed, {
  NormalizedRect? fallback,
}) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final photo = img.decodeImage(file.readAsBytesSync());
  if (photo == null) return null;
  // By the darkest channel: red characters (taxi plates) are all but
  // invisible in brightness, and the plate's edge is found around the
  // digits instead (scans of 2026-10-27).
  final image = inkImage(photo);
  const finder = PlateBoundsFinder();
  return finder.find(image, seed) ??
      (fallback == null ? null : finder.find(image, fallback));
}

/// JPEG of [area] (normalized) of the still at [path], with a little margin,
/// off the UI isolate; null when the image can't be read.
Future<Uint8List?> cropPlateJpeg(String path, NormalizedRect area) async {
  if (!File(path).existsSync()) return null;
  final l = area.left, t = area.top, r = area.right, b = area.bottom;
  return Isolate.run(() {
    final photo = img.decodeImage(File(path).readAsBytesSync());
    if (photo == null) return null;
    final mx = (r - l) * 0.04, my = (b - t) * 0.08;
    final x = ((l - mx) * photo.width).round().clamp(0, photo.width - 1);
    final y = ((t - my) * photo.height).round().clamp(0, photo.height - 1);
    final w =
        ((r - l + 2 * mx) * photo.width).round().clamp(1, photo.width - x);
    final h =
        ((b - t + 2 * my) * photo.height).round().clamp(1, photo.height - y);
    return Uint8List.fromList(img.encodeJpg(
        img.copyCrop(photo, x: x, y: y, width: w, height: h),
        quality: 90));
  });
}
