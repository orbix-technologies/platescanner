import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/ocr_frame.dart';
import 'plate_bounds_finder.dart';
import 'plate_segmenter.dart';

/// Height the plate area is scaled to before segmentation.
const segmentationHeight = 160;

/// Segments [area] (normalized) of the JPEG still at [path], off the UI
/// isolate. Boxes in the result are normalized to [area]. Returns null when
/// the image can't be read.
///
/// [twoRowHint]: the outline search saw a row of letters above the number
/// ([PlateBounds.twoRow]).
Future<PlateSegmentation?> segmentCapture(
  String path,
  NormalizedRect area, {
  bool twoRowHint = false,
}) async {
  if (!File(path).existsSync()) return null;
  final l = area.left, t = area.top, r = area.right, b = area.bottom;
  return Isolate.run(() => segmentCaptureSync(path, NormalizedRect(l, t, r, b),
      twoRowHint: twoRowHint));
}

/// Synchronous body of [segmentCapture] (tests, tools).
PlateSegmentation? segmentCaptureSync(
  String path,
  NormalizedRect area, {
  bool twoRowHint = false,
}) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final photo = img.decodeImage(file.readAsBytesSync());
  if (photo == null) return null;
  final x = (area.left * photo.width).round().clamp(0, photo.width - 1);
  final y = (area.top * photo.height).round().clamp(0, photo.height - 1);
  final w = (area.width * photo.width).round().clamp(1, photo.width - x);
  final h = (area.height * photo.height).round().clamp(1, photo.height - y);
  if (w < 10 || h < 10) return null;
  final crop = img.copyCrop(photo, x: x, y: y, width: w, height: h);
  final plate = img.copyResize(
    crop,
    height: segmentationHeight,
    interpolation: img.Interpolation.average,
  );
  final gray = img.grayscale(plate);
  return PlateSegmenter().segment(
    GrayImage(
      gray.width,
      gray.height,
      gray.getBytes(order: img.ChannelOrder.red),
    ),
    twoRowHint: twoRowHint,
  );
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
  final gray = img.grayscale(photo);
  final image = GrayImage(
    gray.width,
    gray.height,
    gray.getBytes(order: img.ChannelOrder.red),
  );
  const finder = PlateBoundsFinder();
  return finder.find(image, seed) ??
      (fallback == null ? null : finder.find(image, fallback));
}

/// The plate outline around [seed] (normalized) on the JPEG still at
/// [path], with the edges found, off the UI isolate; null when the image
/// can't be read or no plate is found.
Future<PlateBounds?> findCaptureBounds(String path, NormalizedRect seed) async {
  if (!File(path).existsSync()) return null;
  final s = NormalizedRect(seed.left, seed.top, seed.right, seed.bottom);
  return Isolate.run(() => findCaptureBoundsSync(path, s));
}

/// Synchronous body of [findCaptureBounds] (tests, tools).
PlateBounds? findCaptureBoundsSync(String path, NormalizedRect seed) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final photo = img.decodeImage(file.readAsBytesSync());
  if (photo == null) return null;
  final gray = img.grayscale(photo);
  return const PlateBoundsFinder().findDetailed(
    GrayImage(
        gray.width, gray.height, gray.getBytes(order: img.ChannelOrder.red)),
    seed,
  );
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
