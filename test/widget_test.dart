import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'controller_test.dart' show plateOcr;
import 'fake_plate_service.dart';

void main() {
  late FakePlateService fake;
  late PlateReaderController controller;

  setUp(() {
    fake = FakePlateService()..areaOcr = plateOcr;
    controller = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      autoCapture: false,
    );
  });

  Future<void> pumpView(
    WidgetTester tester, {
    PlateScannerOverlayBuilder? overlay,
    ValueChanged<PlateRecord>? onConfirmed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlateScannerView(
            controller: controller,
            overlayBuilder: overlay,
            onPlateConfirmed: onConfirmed,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('full flow: photo → plate number → Done', (tester) async {
    PlateRecord? confirmed;
    await pumpView(tester, onConfirmed: (r) => confirmed = r);
    expect(find.text('Fit the plate inside the frame'), findsOneWidget);

    fake.emitLines(['D-0123456']);
    await tester.pump();
    await tester.pump();
    expect(find.text('Hold steady'), findsOneWidget);

    // Image.file can't load in tests; the flow itself is what's checked.
    await tester.runAsync(() => controller.captureArea());
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    // No area step: straight to the plate number.
    expect(controller.phase, ScanPhase.review);
    expect(find.text('Confirm area'), findsNothing);
    expect(find.text('0123456'), findsOneWidget);
    expect(find.text('AA'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // the circled code
    // Just the plate: no category / region line.
    expect(find.text('Taxi · Addis Ababa'), findsNothing);
    // The process isn't shown: no section cards.
    expect(find.text('1 · Code'), findsNothing);

    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(confirmed?.canonical, '1-AA-0123456');
  });

  testWidgets('edit: fix the number, then Done', (tester) async {
    PlateRecord? confirmed;
    await pumpView(tester, onConfirmed: (r) => confirmed = r);
    fake.emitLines(['D-0123456']);
    await tester.pump();
    await tester.runAsync(() => controller.captureArea());
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.tap(find.byIcon(Icons.edit_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '0123457');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('0123457'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(confirmed?.serial, '0123457');
    expect(confirmed?.editedByUser, isTrue);
  });

  testWidgets('region of interest follows the drawn guide box', (tester) async {
    await pumpView(tester);
    final size = tester.getSize(find.byType(PlateScannerView));
    final guide = PlateScannerView.guideRect(size);
    expect(
      controller.regionOfInterest.left,
      closeTo(guide.left / size.width, 1e-9),
    );
  });

  testWidgets('custom overlay replaces the default HUD', (tester) async {
    await pumpView(
      tester,
      overlay: (context, c) => Text('phase: ${c.phase.name}'),
    );
    expect(find.text('phase: detecting'), findsOneWidget);
    expect(find.bySemanticsLabel('Capture'), findsNothing);
  });

  testWidgets('unsupported device shows the message', (tester) async {
    fake.supported = false;
    await pumpView(tester);
    expect(find.text('This device cannot read plates.'), findsOneWidget);
  });
}
