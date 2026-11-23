import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/models/plate_area.dart';
import 'package:et_plate_reader/src/parsing/plate_family.dart';
import 'package:et_plate_reader/src/recognition/plate_type_classifier.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

PlateSegmentation seg({
  bool twoRow = false,
  NormalizedRect? code,
  List<NormalizedRect> numberChars = const [],
  List<NormalizedRect> latinStack = const [],
  List<NormalizedRect> leftDigits = const [],
  List<NormalizedRect> leftWord = const [],
  bool latinSideBySide = false,
}) {
  final number = numberChars.isEmpty
      ? null
      : numberChars.reduce((a, b) => a.union(b));
  return PlateSegmentation(
    number: number,
    numberChars: numberChars,
    code: code,
    geezStack: const [],
    latinStack: latinStack,
    leftDigits: leftDigits,
    leftWord: leftWord,
    latinSideBySide: latinSideBySide,
    twoRow: twoRow,
    columns: const [],
  );
}

void main() {
  const clf = PlateTypeClassifier();

  test('national ETH from AAA#### OCR line', () {
    final d = clf.classify(TypeFeatures(
      aspect: 4.0,
      ocr: AreaOcr(elements: [
        OcrElement(
          text: 'ABC1234',
          box: const NormalizedRect(0.2, 0.2, 0.9, 0.8),
        ),
        OcrElement(
          text: 'ETH',
          box: const NormalizedRect(0.0, 0.2, 0.15, 0.8),
        ),
      ]),
    ));
    expect(d.family, PlateFamily.nationalEth);
    expect(d.confidence, greaterThan(0.9));
  });

  test('yellow paper → special (police)', () {
    final d = clf.classify(const TypeFeatures(
      aspect: 4.2,
      ocr: AreaOcr(
        elements: [],
        paperColor: [235, 180, 40],
      ),
    ));
    expect(d.family, PlateFamily.special);
    expect(d.reasons, contains('paper:yellow'));
  });

  test('diplomatic left digits → special', () {
    final d = clf.classify(TypeFeatures(
      aspect: 4.0,
      segmentation: seg(
        leftDigits: const [
          NormalizedRect(0.05, 0.2, 0.12, 0.8),
          NormalizedRect(0.12, 0.2, 0.19, 0.8),
        ],
        numberChars: const [
          NormalizedRect(0.4, 0.2, 0.5, 0.8),
          NormalizedRect(0.5, 0.2, 0.6, 0.8),
          NormalizedRect(0.6, 0.2, 0.7, 0.8),
          NormalizedRect(0.7, 0.2, 0.8, 0.8),
        ],
      ),
    ));
    expect(d.family, PlateFamily.special);
  });

  test('segmentation.twoRow → classicTwoRow', () {
    final d = clf.classify(TypeFeatures(
      aspect: 2.0,
      segmentation: seg(
        twoRow: true,
        numberChars: const [
          NormalizedRect(0.1, 0.5, 0.25, 0.9),
          NormalizedRect(0.25, 0.5, 0.4, 0.9),
          NormalizedRect(0.4, 0.5, 0.55, 0.9),
          NormalizedRect(0.55, 0.5, 0.7, 0.9),
          NormalizedRect(0.7, 0.5, 0.85, 0.9),
        ],
      ),
    ));
    expect(d.family, PlateFamily.classicTwoRow);
  });

  test('circle + latin stack → classicSingle', () {
    final d = clf.classify(TypeFeatures(
      aspect: 4.2,
      segmentation: seg(
        code: const NormalizedRect(0.05, 0.2, 0.15, 0.8),
        numberChars: const [
          NormalizedRect(0.35, 0.2, 0.45, 0.8),
          NormalizedRect(0.45, 0.2, 0.55, 0.8),
          NormalizedRect(0.55, 0.2, 0.65, 0.8),
          NormalizedRect(0.65, 0.2, 0.75, 0.8),
          NormalizedRect(0.75, 0.2, 0.85, 0.8),
        ],
        latinStack: const [
          NormalizedRect(0.88, 0.2, 0.95, 0.45),
          NormalizedRect(0.88, 0.5, 0.95, 0.8),
        ],
      ),
    ));
    expect(d.family, PlateFamily.classicSingle);
    expect(d.confidence, greaterThanOrEqualTo(0.9));
  });

  test('no signals → unknown requires review', () {
    final d = clf.classify(const TypeFeatures(aspect: 1.0));
    expect(d.family, PlateFamily.unknown);
    expect(d.requiresReview, isTrue);
  });
}
