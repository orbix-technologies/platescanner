import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'controller_test.dart' show plateOcr;
import 'fake_plate_service.dart';

/// What host apps can set: texts, colours and the steps shown.
void main() {
  late FakePlateService fake;

  PlateReaderController make({bool permission = true}) => PlateReaderController(
        service: fake..areaOcr = plateOcr,
        requestCameraPermission: () async => permission,
        autoCapture: false,
      );

  setUp(() => fake = FakePlateService());

  Future<void> pump(
    WidgetTester tester,
    PlateReaderController controller, {
    PlateScannerOptions options = const PlateScannerOptions(),
    PlateScannerStrings? strings,
    PlateScannerTheme? theme,
    ThemeData? appTheme,
    ValueChanged<PlateRecord>? onConfirmed,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: PlateScannerView(
          controller: controller,
          options: options,
          strings: strings,
          theme: theme,
          onPlateConfirmed: onConfirmed,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  /// Lets automatic steps and the (real-async) reading finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  /// Detect, capture and let the (failing, no real photo) snap finish.
  Future<void> capture(WidgetTester tester, PlateReaderController c) async {
    fake.emitLines(['D-0123456']);
    await tester.pump();
    await tester.runAsync(() async {
      await c.captureArea();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);
  }

  test('built-in texts by locale: Amharic for am, else English', () {
    expect(PlateScannerStrings.forLocale(const Locale('am')).capture, 'አንሳ');
    expect(
        PlateScannerStrings.forLocale(const Locale('fr')).capture, 'Capture');
    expect(PlateScannerStrings.forLocale(null).capture, 'Capture');
  });

  testWidgets('Amharic texts', (tester) async {
    await pump(tester, make(), strings: const PlateScannerStrings.am());
    expect(find.text('ታርጋውን በማዕቀፉ ውስጥ ያስገቡ'), findsOneWidget);
    expect(find.bySemanticsLabel('አንሳ'), findsOneWidget);
  });

  testWidgets('host strings replace single texts', (tester) async {
    await pump(
      tester,
      make(),
      strings: const PlateScannerStrings.en().copyWith(capture: 'Scan now'),
    );
    expect(find.bySemanticsLabel('Scan now'), findsOneWidget);
    expect(find.text('Fit the plate inside the frame'), findsOneWidget);
  });

  testWidgets('buttons follow the host theme, overridable', (tester) async {
    final app = ThemeData(colorSchemeSeed: Colors.teal);
    Color? done() => tester
        .widget<FilledButton>(find.ancestor(
            of: find.text('Done'),
            matching: find.byWidgetPredicate((w) => w is FilledButton)))
        .style
        ?.backgroundColor
        ?.resolve({});
    var c = make();
    await pump(tester, c, appTheme: app);
    await capture(tester, c);
    await tester.pump();
    expect(done(), app.colorScheme.primary);
    await tester.pumpWidget(const SizedBox());
    c = make();
    await pump(tester, c,
        appTheme: app, theme: const PlateScannerTheme(accent: Colors.red));
    await capture(tester, c);
    await tester.pump();
    expect(done(), Colors.red);
  });

  testWidgets('auto: area not snapped to a plate, so the user confirms it',
      (tester) async {
    final c = make();
    await pump(tester, c,
        options: const PlateScannerOptions(confirmArea: ConfirmAreaMode.auto));
    await capture(tester, c);
    expect(c.phase, ScanPhase.confirmingArea);
    expect(c.areaSnapped, isFalse);
    expect(find.text('Confirm area'), findsOneWidget);
  });

  testWidgets('never: reading starts right after capture', (tester) async {
    final c = make();
    await pump(tester, c,
        options: const PlateScannerOptions(confirmArea: ConfirmAreaMode.never));
    await capture(tester, c);
    await tester.pump();
    await tester.pump();
    expect(c.phase, ScanPhase.review);
    expect(find.text('Confirm area'), findsNothing);
  });

  testWidgets('no review: a valid reading is returned without Done',
      (tester) async {
    final c = make();
    PlateRecord? got;
    await pump(
      tester,
      c,
      options: const PlateScannerOptions(
        confirmArea: ConfirmAreaMode.never,
        showReview: false,
      ),
      onConfirmed: (r) => got = r,
    );
    await capture(tester, c);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(got?.canonical, '1-AA-0123456');
  });

  testWidgets('no review, but a reading with problems is still shown',
      (tester) async {
    fake.areaOcr = const AreaOcr(elements: []);
    final c = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      autoCapture: false,
    );
    PlateRecord? got;
    await pump(
      tester,
      c,
      options: const PlateScannerOptions(
        confirmArea: ConfirmAreaMode.never,
        showReview: false,
      ),
      onConfirmed: (r) => got = r,
    );
    await capture(tester, c);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(got, isNull);
    expect(c.phase, ScanPhase.review);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('edit can be turned off', (tester) async {
    final c = make();
    await pump(
      tester,
      c,
      options: const PlateScannerOptions(
        confirmArea: ConfirmAreaMode.never,
        allowEdit: false,
      ),
    );
    await capture(tester, c);
    await tester.pump();
    await tester.pump();
    expect(find.text('Done'), findsOneWidget);
    expect(find.byIcon(Icons.edit_rounded), findsNothing);
  });

  testWidgets('torch can be turned off', (tester) async {
    await pump(tester, make(),
        options: const PlateScannerOptions(showTorch: false));
    expect(find.byIcon(Icons.flashlight_off_rounded), findsNothing);
  });

  testWidgets('camera permission denied: explained, with a settings link',
      (tester) async {
    await pump(tester, make(permission: false));
    expect(find.text('Camera access needed'), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
