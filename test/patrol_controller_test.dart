import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_plate_service.dart';

void main() {
  test('reads a plate passing by, takes its photo, reports it on Finish',
      () async {
    final fake = FakePlateService();
    final seen = <String>[];
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      onVehicle: (v) => seen.add(v.plate),
      recordSessions: false,
    );
    await c.start();
    expect(c.isRunning, isTrue);
    for (var i = 0; i < 4; i++) {
      fake.emitLines(['B05475']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(c.inView, hasLength(1));
    expect(fake.captures, 1); // one photo per vehicle
    final all = await c.stop();
    expect(all.single.serial, 'B05475');
    expect(all.single.photoPath, fake.framePath);
    expect(seen, contains('B05475'));
    c.dispose();
  });

  test('a vehicle that is not the focus gets a video frame as its photo',
      () async {
    final fake = FakePlateService();
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      recordSessions: false,
    );
    await c.start();
    for (var i = 0; i < 5; i++) {
      fake.emitFrame(const [
        // Near: the focus.
        OcrLine(text: 'B05475', box: NormalizedRect(0.1, 0.3, 0.9, 0.4)),
        // Further away.
        OcrLine(text: '97073', box: NormalizedRect(0.35, 0.7, 0.6, 0.74)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final all = await c.stop();
    final near = all.firstWhere((v) => v.serial == 'B05475');
    final far = all.firstWhere((v) => v.serial == '97073');
    expect(near.photoPath, fake.framePath);
    expect(near.photos, 1);
    expect(far.photoPath, fake.grabPath);
    expect(far.photos, 0); // not read in full
    expect(fake.grabs, 1);
    c.dispose();
  });

  test('closing without Finish still reports the vehicles in view', () async {
    final fake = FakePlateService();
    final seen = <String>[];
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      onVehicle: (v) => seen.add(v.plate),
      recordSessions: false,
    );
    await c.start();
    for (var i = 0; i < 3; i++) {
      fake.emitLines(['B05475']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(seen, isNot(contains('B05475'))); // still in view
    c.dispose();
    expect(seen, contains('B05475'));
  });

  test('a still that hangs gives way to the video frame', () {
    fakeAsync((async) {
      final fake = FakePlateService()..stillHangs = true;
      final c = PatrolController(
        service: fake,
        requestCameraPermission: () async => true,
        recordSessions: false,
      );
      c.start();
      async.flushMicrotasks();
      for (var i = 0; i < 3; i++) {
        fake.emitLines(['B05475']);
        async.elapse(const Duration(milliseconds: 20));
      }
      expect(fake.captures, 1);
      expect(fake.grabs, 0);
      async.elapse(PatrolController.stillTimeout);
      expect(fake.grabs, 1);
      expect(c.inView.single.photoPath, fake.grabPath);
      c.dispose();
    });
  });

  test(
      'a vehicle that left before its picture was ready is reported again '
      'with it', () async {
    final fake = FakePlateService()
      ..grabDelay = const Duration(milliseconds: 1600);
    final reports = <String?>[];
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      onVehicle: (v) => reports.add(v.photoPath),
      recordSessions: false,
    );
    await c.start();
    // Half off the right edge: not fully in view, so not the focus.
    for (var i = 0; i < 3; i++) {
      fake.emitFrame(const [
        OcrLine(text: 'B05475', box: NormalizedRect(0.7, 0.4, 1.1, 0.45)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Gone: reported after 0.9 s, before the picture (1.6 s) is back.
    for (var i = 0; i < 9; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      fake.emitFrame(const []);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reports, [null]);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(reports, [null, fake.grabPath]);
    c.dispose();
  });

  test('a glance (one frame) at text with no plate around it is dropped',
      () async {
    final fake = FakePlateService(); // its pictures show no plate
    final reports = <String>[];
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      onVehicle: (v) => reports.add(v.plate),
      recordSessions: false,
    );
    await c.start();
    // A clock read once ("Oct 23 11:54" as "Ot 23 154"), then gone.
    fake.emitFrame(const [
      OcrLine(text: 'Ot 23 154', box: NormalizedRect(0.82, 0.26, 0.97, 0.28)),
    ]);
    for (var i = 0; i < 9; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      fake.emitFrame(const []);
    }
    final all = await c.stop();
    expect(reports, isEmpty);
    expect(all, isEmpty);
    c.dispose();
  });

  test('the focus is read first from the very frame its number was read in',
      () async {
    final fake = FakePlateService();
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      recordSessions: false,
    );
    await c.start();
    for (var i = 1; i <= 3; i++) {
      fake.emitFrame(const [
        OcrLine(text: 'B05475', box: NormalizedRect(0.2, 0.4, 0.8, 0.48)),
      ], id: i);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(fake.frameImages.first, 1); // the frame it became the focus in
    expect(fake.captures, 1); // the still too, as it wasn't read in full
    final v = (await c.stop()).single;
    expect(v.photos, 1);
    c.dispose();
  });

  test('a diplomatic number with no plate seen around it is dropped', () async {
    // A sticker: "10 8161" reads like an embassy number and four digits.
    final fake = FakePlateService(); // its pictures show no plate
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      recordSessions: false,
    );
    await c.start();
    for (var i = 0; i < 5; i++) {
      fake.emitFrame(const [
        OcrLine(text: '10 8161', box: NormalizedRect(0.3, 0.4, 0.6, 0.45)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await c.stop(), isEmpty);
    c.dispose();
  });

  test('a number read twice with nothing around it is not a plate; '
      'with its region it is', () async {
    final fake = FakePlateService(); // its pictures show no plate
    final c = PatrolController(
      service: fake,
      requestCameraPermission: () async => true,
      recordSessions: false,
    );
    await c.start();
    for (var i = 0; i < 2; i++) {
      fake.emitFrame(const [
        // A sticker's number.
        OcrLine(text: '18140', box: NormalizedRect(0.1, 0.2, 0.3, 0.23)),
        // A plate read twice, with its region beside the number.
        OcrLine(text: 'A12345', box: NormalizedRect(0.3, 0.6, 0.6, 0.65)),
        OcrLine(text: 'AA', box: NormalizedRect(0.62, 0.6, 0.68, 0.65)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final all = await c.stop();
    expect(all.map((v) => v.plate), ['AA-A12345']);
    c.dispose();
  });

  test('camera permission denied', () async {
    final c = PatrolController(
      service: FakePlateService(),
      requestCameraPermission: () async => false,
      recordSessions: false,
    );
    await c.start();
    expect(c.isRunning, isFalse);
    expect(c.errorCode, PlateReaderErrorCode.permissionDenied);
    c.dispose();
  });
}
