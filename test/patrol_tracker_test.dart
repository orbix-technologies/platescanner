import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plates sliding through the frame while walking or riding past.
void main() {
  final t0 = DateTime(2026, 10, 20, 10);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  OcrLine line(String text, double x, {double y = 0.5, double w = 0.3}) =>
      OcrLine(
        text: text,
        box: NormalizedRect(x, y, x + w, y + 0.05),
      );

  test('one plate across frames is one vehicle, reported after it passes', () {
    final t = PatrolTracker();
    final reported = <PatrolVehicle>[];
    // 8 frames, 120 ms apart, the plate moving right to left; one misread.
    final reads = [
      'A12345', 'A12345', 'A1234S', 'A12345', //
      'A12345', 'A12345', 'A12345', 'A12345',
    ];
    for (var i = 0; i < reads.length; i++) {
      reported.addAll(t.update([line(reads[i], 0.6 - i * 0.07)], at(i * 120)));
    }
    expect(reported, isEmpty); // still in view
    expect(t.active, hasLength(1));
    // Gone from view for a second: reported once.
    reported.addAll(t.update(const [], at(2000)));
    expect(reported, hasLength(1));
    final v = reported.single;
    expect(v.serial, 'A12345');
    expect(v.votes, 8); // the S read as 5 still agrees on the number
    expect(v.needsCheck, isFalse);
  });

  test('vehicles one after another are each reported', () {
    final t = PatrolTracker();
    final out = <PatrolVehicle>[];
    var ms = 0;
    for (final plate in ['12345', '67890', 'B05475']) {
      for (var i = 0; i < 5; i++) {
        out.addAll(t.update([line(plate, 0.7 - i * 0.1)], at(ms)));
        ms += 120;
      }
      ms += 1200; // gap between parked cars
      out.addAll(t.update(const [], at(ms)));
    }
    expect(out.map((v) => v.serial), ['12345', '67890', 'B05475']);
  });

  test('two plates in view at once are two vehicles', () {
    final t = PatrolTracker();
    for (var i = 0; i < 4; i++) {
      t.update([
        line('11111', 0.05, y: 0.3, w: 0.2),
        line('22222', 0.6, y: 0.7, w: 0.2),
      ], at(i * 120));
    }
    final out = t.finishAll();
    expect(out.map((v) => v.serial).toSet(), {'11111', '22222'});
  });

  test('the same plate seen again soon is not a new vehicle', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([line('54321', 0.5)], at(i * 100));
    }
    t.update(const [], at(1500));
    // Its rear plate, a few seconds later.
    for (var i = 0; i < 3; i++) {
      t.update([line('54321', 0.2)], at(5000 + i * 100));
    }
    final rest = t.finishAll();
    expect(rest, isEmpty);
    expect(t.vehicles, hasLength(1));
    expect(t.vehicles.single.votes, 6);
  });

  test('a number read once is marked to check; text in view is not a plate',
      () {
    final t = PatrolTracker();
    t.update([line('77777', 0.4), line('Toyota', 0.1, y: 0.8)], at(0));
    t.update([line('12:45', 0.8, y: 0.1)], at(100));
    final out = t.finishAll();
    expect(out, hasLength(1));
    expect(out.single.serial, '77777');
    expect(out.single.needsCheck, isTrue);
  });

  test('the new national number', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([line('AAAGO00', 0.5)], at(i * 100));
    }
    final v = t.finishAll().single;
    expect(v.code, 'ETH');
    expect(v.serial, 'AAA0000');
    expect(v.toRecord().serial, 'AAA0000');
  });

  test('diplomatic: the embassy number is not joined to the number', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('63-0123', 0.05, y: 0.3, w: 0.2),
        line('65-0123', 0.6, y: 0.7, w: 0.2),
      ], at(i * 120));
    }
    final out = t.finishAll();
    // Same number, two embassies: two vehicles.
    expect(out, hasLength(2));
    expect(out.map((v) => v.code).toSet(), {'CD'});
    expect(out.map((v) => v.serial).toSet(), {'0123'});
    expect(out.map((v) => v.embassy).toSet(), {'63', '65'});
    // A normal number is not taken for one.
    final n = PatrolTracker()..update([line('0123456', 0.4)], at(0));
    expect(n.finishAll().single.code, isNot('CD'));
  });

  test('a series letter misread as a digit is the same vehicle', () {
    final t = PatrolTracker();
    final reads = ['808468', 'B08468', '808468', '808468', 'B08468'];
    for (var i = 0; i < reads.length; i++) {
      // Far apart in the frame between reads (camera moving).
      t.update([line(reads[i], i.isEven ? 0.1 : 0.6)], at(i * 120));
    }
    final v = t.finishAll();
    expect(v, hasLength(1));
    expect(v.single.serial, 'B08468'); // the form with the letter
    expect(v.single.votes, 5);
  });

  test('4-digit numbers (stickers, phone numbers) are not vehicles', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([line('8161', 0.4)], at(i * 120));
    }
    expect(t.finishAll(), isEmpty);
  });

  test('the circled code read as O / G is not a series letter', () {
    final t = PatrolTracker();
    for (final (i, r) in ['O30138', 'G30138', '30138', 'O30138'].indexed) {
      t.update([line(r, 0.4)], at(i * 120));
    }
    final v = t.finishAll().single;
    expect(v.serial, '30138');
    expect(v.votes, 4);
  });

  test('vehicles that end up with the same number are merged', () {
    final t = PatrolTracker();
    // First car: mostly misread at first, settles on 59100 later.
    for (final (i, r) in ['59160', '59100', '59100'].indexed) {
      t.update([line(r, 0.4)], at(i * 120));
    }
    t.update(const [], at(2000));
    for (var i = 0; i < 2; i++) {
      t.update([line('59100', 0.4)], at(10000 + i * 120));
    }
    t.finishAll();
    expect(t.vehicles.where((v) => v.serial == '59100'), hasLength(1));
  });

  test('phone numbers and web text on vehicles are not plates', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('+350 200 59100', 0.3),
        line('sales 0911 22 33 44', 0.3, y: 0.7),
        line('toyota-gib.com 59100', 0.3, y: 0.1),
      ], at(i * 120));
    }
    expect(t.finishAll(), isEmpty);
  });

  test("a two-row plate's region is read from its top row", () {
    // Live text reads the top row as one line: the circle as O / 9, the
    // Ge'ez pair as small "hh", then the region in capitals.
    for (final top in ['OhhAA', '9h hA A', 'hh AA', 'AA']) {
      final t = PatrolTracker();
      for (var i = 0; i < 3; i++) {
        t.update([
          OcrLine(
              text: top, box: const NormalizedRect(0.32, 0.44, 0.58, 0.465)),
          line('C61474', 0.3, y: 0.47, w: 0.3),
        ], at(i * 120));
      }
      final v = t.finishAll().single;
      expect(v.plate, 'AA-C61474', reason: top);
      expect(v.toRecord().layout, PlateLayout.twoRow, reason: top);
    }
  });

  test("the Ge'ez letters read as hh are not Harari", () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        OcrLine(text: 'hh', box: const NormalizedRect(0.32, 0.44, 0.42, 0.465)),
        line('C57972', 0.3, y: 0.47, w: 0.3),
      ], at(i * 120));
    }
    expect(t.finishAll().single.regionCode, isNot('HR'));
  });

  test('a one-row plate keeps the region beside its number', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('A12345', 0.3, w: 0.3),
        line('AA', 0.62, w: 0.06),
      ], at(i * 120));
    }
    final v = t.finishAll().single;
    expect(v.regionCode, 'AA');
    expect(v.toRecord().layout, PlateLayout.singleRow);
  });

  test('text outside the visible preview is ignored', () {
    // The camera frame is wider than the screen: boxes past its edges.
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('B05475', 1.1, w: 0.2),
        line('A12345', -0.4, w: 0.2),
      ], at(i * 120));
    }
    expect(t.finishAll(), isEmpty);
  });

  test('mobile numbers on stickers are not plates', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('0930103 B0', 0.1, y: 0.2),
        line('0911223344', 0.1, y: 0.5),
        line('07 112233', 0.1, y: 0.8),
      ], at(i * 120));
    }
    expect(t.finishAll(), isEmpty);
  });

  test('text on a screen is not a plate', () {
    // What patrol read off a computer screen (adb ports, log lines).
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('10.42.0.165:34585 device', 0.1, y: 0.2),
        line('95024 verbose', 0.1, y: 0.4),
        line('M04036 build', 0.1, y: 0.6),
        line('10:45', 0.6, y: 0.8),
      ], at(i * 120));
    }
    expect(t.finishAll(), isEmpty);
  });

  test("a neighbour's address doesn't lend its digits as the code", () {
    // The number on a line of its own, the address beside it.
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([
        line('10.42.0.165:', 0.1, w: 0.25),
        line('34585', 0.37, w: 0.2),
      ], at(i * 120));
    }
    final v = t.finishAll().single;
    expect(v.serial, '34585');
    expect(v.code, isNull);
  });

  test('the circle read as O in front of an old plate is not a national one',
      () {
    final t = PatrolTracker();
    for (var i = 0; i < 2; i++) {
      t.update([line('ONB2540', 0.4)], at(i * 120));
    }
    expect(t.finishAll().map((v) => v.code), isNot(contains('ETH')));
  });

  PlateCandidate full(String? code, String? region, String serial,
          {PlateLayout layout = PlateLayout.singleRow}) =>
      PlateCandidate(
        code: code,
        regionCode: region,
        serial: serial,
        layout: layout,
        rawText: '',
        confidence: 1,
        issues: const EthiopianPlateParser()
            .validate(code: code, regionCode: region, serial: serial),
      );

  test('a full reading completes the plate and survives live reads', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([line('97073', 0.4)], at(i * 120));
    }
    final v = t.active.single;
    expect(v.complete, isFalse);
    // The full read of its photo: code and region too.
    expect(v.applyFull(full('3', 'AA', '97073')), isTrue);
    expect(v.complete, isTrue);
    expect(v.plate, '3-AA-97073');
    // More live reads (number only) keep the full plate.
    for (var i = 3; i < 6; i++) {
      t.update([line('97073', 0.4)], at(i * 120));
    }
    expect(v.plate, '3-AA-97073');
    // A worse full read doesn't replace it; a different number is refused.
    expect(v.applyFull(full('3', null, '97073')), isFalse);
    expect(v.applyFull(full('2', 'AA', '12345')), isFalse);
    expect(t.finishAll().single.plate, '3-AA-97073');
  });

  test('the record keeps the layout of the full reading', () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([line('B94491', 0.4)], at(i * 120));
    }
    final v = t.active.single;
    expect(v.toRecord().layout, PlateLayout.singleRow);
    v.applyFull(full('2', 'AA', 'B94491', layout: PlateLayout.twoRow));
    expect(v.toRecord().layout, PlateLayout.twoRow);
  });

  test('a full reading with the series letter misread keeps code and region',
      () {
    final t = PatrolTracker();
    for (var i = 0; i < 3; i++) {
      t.update([line('C70677', 0.4)], at(i * 120));
    }
    final v = t.active.single;
    // The number crop read C as 1; circle and region read fine.
    expect(v.applyFull(full('2', 'AA', '170677')), isTrue);
    expect(v.plate, '2-AA-C70677');
  });

  test('a misread reported first takes the right number when merged', () {
    final t = PatrolTracker();
    // Read twice as C69061, then gone.
    for (var i = 0; i < 2; i++) {
      t.update([line('C69061', 0.4)], at(i * 120));
    }
    for (var i = 2; i < 12; i++) {
      t.update(const [], at(i * 120));
    }
    expect(t.vehicles.single.serial, 'C69061');
    t.takeMerges();
    // The same plate, well read as C69001, leaves soon after.
    for (var i = 12; i < 20; i++) {
      t.update([line('C69001', 0.4)], at(i * 120));
    }
    for (var i = 20; i < 30; i++) {
      t.update(const [], at(i * 120));
    }
    final m = t.takeMerges();
    expect(t.vehicles, hasLength(1));
    expect(m.updated.single.serial, 'C69001');
    expect(m.gone, isEmpty);
  });
}
