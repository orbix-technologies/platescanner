import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = EthiopianPlateParser();

  List<OcrLine> lines(List<String> texts, {double confidence = 0.95}) => [
        for (var i = 0; i < texts.length; i++)
          OcrLine(
            text: texts[i],
            box: NormalizedRect(0.1, 0.3 + i * 0.2, 0.9, 0.45 + i * 0.2),
            confidence: confidence,
          ),
      ];

  group('single-row plates', () {
    test('code, region and lettered serial', () {
      final c = parser.parse(lines(['2 AA A12345']));
      expect(c.code, '2');
      expect(c.regionCode, 'AA');
      expect(c.serial, 'A12345');
      expect(c.layout, PlateLayout.singleRow);
      expect(c.isValid, isTrue);
      expect(c.key, '2-AA-A12345');
    });

    test('plain five-digit serial', () {
      final c = parser.parse(lines(['3 OR 54321']));
      expect([c.code, c.regionCode, c.serial], ['3', 'OR', '54321']);
      expect(c.isValid, isTrue);
    });

    test('ignores the ETHIOPIA legend and Amharic text', () {
      final c = parser.parse(lines(['ETHIOPIA ኢትዮጵያ', '1 AM 01234']));
      expect([c.code, c.regionCode, c.serial], ['1', 'AM', '01234']);
    });

    test('code box merged into the serial', () {
      final c = parser.parse(lines(['AA 2A12345']));
      expect(c.code, '2');
      expect(c.serial, 'A12345');
      expect(c.isValid, isTrue);
    });

    test('serial split across two tokens', () {
      final c = parser.parse(lines(['2 AA A 12345']));
      expect(c.serial, 'A12345');
    });
  });

  group('two-row plates', () {
    test('code and region above the serial', () {
      final c = parser.parse(lines(['2 DR', 'B 67890']));
      expect([c.code, c.regionCode, c.serial], ['2', 'DR', 'B67890']);
      expect(c.layout, PlateLayout.twoRow);
    });

    test('Amharic region label is recognised', () {
      final c = parser.parse(lines(['4 ኦሮ', '11111']));
      expect(c.regionCode, 'OR');
      expect(c.isValid, isTrue);
    });
  });

  group('OCR confusions', () {
    test('letters read inside the digit run are corrected', () {
      final c = parser.parse(lines(['2 AA A1234S']));
      expect(c.serial, 'A12345');
      expect(c.confidence, lessThan(0.95));
    });

    test('O read as 0 in the region code', () {
      final c = parser.parse(lines(['2 0R 12345']));
      expect(c.regionCode, 'OR');
    });

    test('I read for the code digit 1', () {
      final c = parser.parse(lines(['I AA 12345']));
      expect(c.code, '1');
    });

    test('mostly-letter words are not taken as serials', () {
      final c = parser.parse(lines(['TOYOTA']));
      expect(c.serial, isNull);
    });

    test('region alias TIG maps to TG', () {
      final c = parser.parse(lines(['2 TIG 12345']));
      expect(c.regionCode, 'TG');
    });
  });

  group("new Ge'ez-format plates", () {
    // Real ML Kit output for the EBR sample plate (circled 1, Ge'ez region,
    // 0123456, stacked A/A): the ring is read as "D-" and the digit is lost.
    const plateLine = OcrLine(
      text: 'D-0123456',
      box: NormalizedRect(0.048, 0.311, 0.930, 0.470),
      confidence: 0.67,
    );
    const stackedTop = OcrLine(
      text: 'A',
      box: NormalizedRect(0.955, 0.33, 0.99, 0.38),
      confidence: 0.9,
    );
    const stackedBottom = OcrLine(
      text: 'A',
      box: NormalizedRect(0.955, 0.42, 0.99, 0.47),
      confidence: 0.9,
    );

    test('seven-digit serial, code from the circled-code pass', () {
      final c = parser.parse(
        [plateLine, stackedTop, stackedBottom],
        codeHint: '1',
      );
      expect([c.code, c.regionCode, c.serial], ['1', 'AA', '0123456']);
      expect(c.isValid, isTrue);
    });

    test('the ring read as D is not taken as a serial letter', () {
      final c = parser.parse([plateLine]);
      expect(c.serial, '0123456');
      expect(c.code, isNull);
      expect(c.issues, contains(PlateIssue.missingCode));
    });

    test('a watermark letter read as a digit loses to the code pass', () {
      final c = parser.parse([
        plateLine,
        stackedTop,
        stackedBottom,
        const OcrLine(
          text: 'z.com/Licence_Plates',
          box: NormalizedRect(0.1, 0.44, 0.9, 0.47),
        ),
      ], codeHint: '1');
      expect(c.code, '1');
    });

    test('circled digit from OCR', () {
      final c = parser.parse(lines(['① 0123456 AA']));
      expect([c.code, c.regionCode, c.serial], ['1', 'AA', '0123456']);
    });

    test('parenthesised code', () {
      final c = parser.parse(lines(['(3) 654321 OR']));
      expect([c.code, c.regionCode, c.serial], ['3', 'OR', '654321']);
    });

    test('stacked letters on one line', () {
      final c = parser.parse(lines(['1 0123456 A A']), codeHint: null);
      expect(c.regionCode, 'AA');
    });

    test('stacked Ge\'ez region', () {
      final c = parser.parse([
        const OcrLine(text: 'አ', box: NormalizedRect(0.1, 0.3, 0.15, 0.35)),
        const OcrLine(text: 'አ', box: NormalizedRect(0.1, 0.4, 0.15, 0.45)),
        const OcrLine(
          text: '0123456',
          box: NormalizedRect(0.2, 0.3, 0.9, 0.45),
        ),
      ], codeHint: '2');
      expect([c.code, c.regionCode, c.serial], ['2', 'AA', '0123456']);
    });

    test('an unknown code hint is ignored', () {
      final c = parser.parse([plateLine], codeHint: '9');
      expect(c.code, isNull);
    });
  });

  test('old merged code box still splits when no code is found', () {
    final c = parser.parse(lines(['AA 212345']));
    expect([c.code, c.serial], ['2', '12345']);
  });

  group('special plates', () {
    test('diplomatic plate needs no region', () {
      final c = parser.parse(lines(['CD 12345']));
      expect(c.code, 'CD');
      expect(c.regionCode, isNull);
      expect(c.isValid, isTrue);
    });
  });

  group('validation', () {
    test('missing fields are reported', () {
      final c = parser.parse(lines(['AA']));
      expect(
        c.issues,
        containsAll([PlateIssue.missingCode, PlateIssue.missingSerial]),
      );
      expect(c.isValid, isFalse);
    });

    test('missing region on a numeric code', () {
      final c = parser.parse(lines(['2 12345']));
      expect(c.issues, [PlateIssue.missingRegion]);
    });

    test('requireRegion: false accepts plates without a region', () {
      const lax = EthiopianPlateParser(requireRegion: false);
      expect(lax.parse(lines(['2 12345'])).isValid, isTrue);
    });

    test('unknown code is flagged on edited values', () {
      expect(
        parser.validate(code: '9', regionCode: 'AA', serial: '12345'),
        [PlateIssue.unknownCode],
      );
    });

    test('normalizeSerial', () {
      expect(parser.normalizeSerial('a 12345'), 'A12345');
      expect(parser.normalizeSerial('1234'), isNull);
      expect(parser.normalizeSerial('012 3456'), '0123456');
      expect(parser.normalizeSerial('A123456'), isNull);
    });

    test('every region code round-trips', () {
      for (final r in EthiopianRegion.values) {
        final c = parser.parse(lines(['2 ${r.code} 12345']));
        expect(c.regionCode, r.code, reason: r.name);
      }
    });
  });

  test('format', () {
    final r = PlateRecord(
      id: 'x',
      code: '2',
      regionCode: 'AA',
      serial: 'A12345',
      layout: PlateLayout.singleRow,
      rawText: '',
      confidence: 1,
      capturedAt: DateTime(2026),
    );
    expect(parser.format(r), '2 · AA · A12345');
    expect(r.canonical, '2-AA-A12345');
  });
}
