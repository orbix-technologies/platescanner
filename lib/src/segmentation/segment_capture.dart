import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

import '../models/ocr_frame.dart';
import 'plate_segmenter.dart';

/// Height the plate area is scaled to before segmentation.
const segmentationHeight = 160;

/// Segments [area] (normalized) of the JPEG still at [path], off the UI
/// isolate. Boxes in the result are normalized to [area]. Returns null when
/// the image can't be read.
Future<PlateSegmentation?> segmentCapture(
  String path,
  NormalizedRect area,
) async {
  if (!File(path).existsSync()) return null;
  final l = area.left, t = area.top, r = area.right, b = area.bottom;
  return Isolate.run(
      () => segmentCaptureSync(path, NormalizedRect(l, t, r, b)));
}

/// Synchronous body of [segmentCapture] (tests, tools).
PlateSegmentation? segmentCaptureSync(String path, NormalizedRect area) {
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
  );
}
