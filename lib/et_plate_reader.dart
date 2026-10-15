/// Ethiopian plate reader — embeddable camera + OCR plate capture.
///
/// ```dart
/// import 'package:et_plate_reader/et_plate_reader.dart';
/// ```
///
/// For optional SQLite persistence:
///
/// ```dart
/// import 'package:et_plate_reader/persistence.dart';
/// ```
library;

export 'src/controller/plate_reader_controller.dart'
    show PlateReaderController, ScanPhase;
export 'src/exceptions/plate_reader_exception.dart';
export 'src/models/ocr_frame.dart' show NormalizedRect, OcrLine, OcrFrame;
export 'src/models/plate_record.dart'
    show PlateCandidate, PlateIssue, PlateLayout, PlateLocation, PlateRecord;
export 'src/parsing/ethiopian_plate_parser.dart' show EthiopianPlateParser;
export 'src/parsing/ethiopian_region.dart' show EthiopianRegion;
export 'src/parsing/plate_service_type.dart' show PlateServiceType;
export 'src/parsing/plate_stability_voter.dart' show PlateStabilityVoter;
export 'src/recognition/plate_availability.dart'
    show PlateReader, PlateReaderAvailability, PlateReaderAvailabilityStatus;
export 'src/recognition/plate_recognition_service.dart'
    show PlateRecognitionService, PlateRecognitionServiceFactory;
export 'src/widgets/plate_scanner_view.dart'
    show PlateScannerView, PlateScannerOverlayBuilder;
