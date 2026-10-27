import '../models/ocr_frame.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_plate_parser.dart';
import '../parsing/plate_section_reader.dart';
import '../recognition/plate_recognition_service.dart';
import '../segmentation/plate_bounds_finder.dart';
import '../segmentation/plate_segmenter.dart';
import '../segmentation/segment_capture.dart';
import 'patrol_tracker.dart';

/// What [PatrolRefiner.refine] did, step by step (logs, probes).
class RefineTrace {
  /// Text of the OCR element where the number was found on the photo.
  String? numberText;

  /// Its box, or the logged box when the number wasn't found.
  NormalizedRect? numberBox;

  /// The area searched for the plate outline, and the plate area used.
  NormalizedRect? seed, area;

  /// Whether the area came from the outline search (else the seed).
  bool snapped = false;

  /// Whether that outline has the plate's own top and bottom edges
  /// ([PlateBounds.isPlate]).
  bool outline = false;

  /// The sections found.
  PlateSegmentation? segmentation;

  /// Every crop read: role+index → reads.
  Map<String, List<String?>> reads = {};

  /// The full reading.
  PlateCandidate? candidate;

  /// Why it stopped early, if it did.
  String? failure;

  /// For JSON logs.
  Map<String, Object?> toJson() {
    Map<String, double>? r(NormalizedRect? x) => x == null
        ? null
        : {
            'left': x.left,
            'top': x.top,
            'right': x.right,
            'bottom': x.bottom,
          };
    final s = segmentation;
    return {
      'numberText': numberText,
      'numberBox': r(numberBox),
      'seed': r(seed),
      'area': r(area),
      'snapped': snapped,
      'outline': outline,
      if (s != null)
        'segmentation': {
          'found': s.found,
          'twoRow': s.twoRow,
          'numberChars': s.numberChars.length,
          'circle': s.code != null,
          'latin': s.latinStack.length,
          'geez': s.geezStack.length,
          'leftDigits': s.leftDigits.length,
          'notes': s.notes,
        },
      'reads': reads,
      if (candidate != null)
        'candidate': {
          'code': candidate!.code,
          'region': candidate!.regionCode,
          'serial': candidate!.serial,
          'issues': [for (final i in candidate!.issues) i.name],
        },
      'failure': failure,
    };
  }
}

/// Reads a patrol vehicle's photo in full, as a single scan does: finds its
/// number on the photo, the plate outline around it, the sections, and
/// reads each section crop. Adds the code and region the live text rarely
/// carries.
class PatrolRefiner {
  /// Creates a refiner using [service] for OCR.
  const PatrolRefiner(this.service,
      {this.parser = const EthiopianPlateParser(requireRegion: false)});

  /// Native OCR (no camera needed).
  final PlateRecognitionService service;

  /// Reads plate numbers.
  final EthiopianPlateParser parser;

  /// Where to look for the plate outline around its number's box: the
  /// plate reaches past the number (circle and Ge'ez left, letters right,
  /// the top row of two-row plates above).
  static NormalizedRect seedAround(NormalizedRect number) {
    final h = number.height;
    double c(double x) => x.clamp(0.0, 1.0);
    return NormalizedRect(c(number.left - 1.6 * h), c(number.top - 0.5 * h),
        c(number.right + 0.9 * h), c(number.bottom + 0.5 * h));
  }

  /// Reads [photoPath] for a vehicle whose live number is [serial], seen at
  /// [box] (normalized; the photo is a moment later, so the plate may have
  /// moved). [trace] records each step.
  Future<PlateCandidate?> refine(
    String photoPath,
    String serial,
    NormalizedRect box, {
    RefineTrace? trace,
  }) async {
    final t = trace ?? RefineTrace();
    // 1. The number on the photo itself.
    final whole = await service.recognizeArea(
        photoPath, const NormalizedRect(0, 0, 1, 1),
        sectionPasses: false);
    final want = PatrolVehicle.lookAlike(serial);
    var at = box;
    double? nearest;
    for (final e in whole.elements) {
      final clean = e.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final matches =
          (want.length >= 4 && PatrolVehicle.lookAlike(clean).contains(want)) ||
              // The new national plate's notched 0 reads as G ("AAAGO00").
              parser.readNationalSerial(clean) == serial;
      if (!matches) continue;
      // The same number can appear more than once (other plates, a sheet
      // of samples): the one nearest where the plate was seen.
      final d = (e.box.centerX - box.centerX).abs() +
          (e.box.centerY - box.centerY).abs();
      if (nearest == null || d < nearest) {
        nearest = d;
        at = e.box;
        t.numberText = e.text;
      }
    }
    t.numberBox = at;
    if (t.numberText == null) t.failure = 'number not found on photo';

    // 2. The plate outline around it.
    final seed = seedAround(at);
    t.seed = seed;
    final bounds = await findCaptureBounds(photoPath, seed);
    t.snapped = bounds != null;
    t.outline = bounds?.isPlate ?? false;
    final area = bounds?.area ?? seed;
    t.area = area;

    // 3. Sections, then each section read alone.
    final seg = await segmentCapture(photoPath, area,
        twoRowHint: bounds?.twoRow ?? false);
    t.segmentation = seg;
    if (seg == null || !seg.found) {
      t.failure ??= 'no sections found';
      return null;
    }
    const reader = PlateSectionReader();
    final crops = reader.cropsFor(seg, area);
    final reads =
        await service.readCrops(photoPath, [for (final c in crops) c.spec]);
    for (var i = 0; i < crops.length && i < reads.length; i++) {
      t.reads['${crops[i].role}${crops[i].index}'] = reads[i];
    }
    final ocr =
        await service.recognizeArea(photoPath, area, sectionPasses: false);
    final r = reader.read(seg, crops, reads, ocr).candidate;
    t.candidate = r;
    return r;
  }
}
