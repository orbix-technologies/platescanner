// On-device check that every scan attempt is logged, including attempts
// that never captured a still. Uses the real camera, ML Kit and detector.
//
// Run on a connected Android phone (camera permission granted):
//   cd example && flutter drive --keep-app-running \
//       --driver=test_driver/integration_test.dart \
//       --target=integration_test/session_log_test.dart
// --keep-app-running matters: without it `flutter drive` uninstalls the app
// when done, and so does `flutter test integration_test/...`, wiping the
// camera permission, the scan history and the logs on the phone.
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// `cache/et_plate_logs/` in the app's data directory, where the scanner
/// writes its stills and logs (Flutter's temp dir is the sibling
/// `code_cache/`).
Directory get _logDir {
  final temp = Directory.systemTemp.path;
  final cache = temp.endsWith('/code_cache')
      ? '${temp.substring(0, temp.length - 'code_cache'.length)}cache'
      : temp;
  return Directory('$cache/et_plate_logs');
}

Set<String> _logs() => _logDir.existsSync()
    ? _logDir
        .listSync()
        .map((f) => f.path)
        .where((p) => p.endsWith('.json'))
        .toSet()
    : <String>{};

/// Pumps frames for [d] without waiting for the camera preview to settle.
Future<void> _run(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the scanner from the home screen and lets it look for a plate.
Future<void> _openScanner(WidgetTester tester) async {
  await tester.pumpWidget(const ExampleApp());
  await _run(tester, const Duration(seconds: 2));
  await tester.tap(find.text('Scan plate'));
  await _run(tester, const Duration(seconds: 4));
  expect(find.byTooltip('Close'), findsOneWidget,
      reason: 'scanner open (camera permission granted?)');
}

/// The one log written since [before], decoded.
Future<Map<String, Object?>> _newLog(
  WidgetTester tester,
  Set<String> before,
) async {
  await _run(tester, const Duration(seconds: 1)); // let the save finish
  final added = _logs().difference(before);
  expect(added, hasLength(1), reason: 'one new session log');
  return jsonDecode(File(added.single).readAsStringSync())
      as Map<String, Object?>;
}

List<String> _events(Map<String, Object?> log) =>
    [for (final e in log['events']! as List) (e as Map)['event'] as String];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('closing the scanner with ✕ before a capture is logged',
      (tester) async {
    final before = _logs();
    await _openScanner(tester);

    await tester.tap(find.byTooltip('Close'));
    final log = await _newLog(tester, before);

    expect(log['frame'], isNull, reason: 'no still was captured');
    final events = _events(log);
    expect(events.first, 'start');
    expect(events, contains('detect'), reason: 'camera frames were read');
    expect(events.last, 'cancel');
  });

  testWidgets('leaving the scanner with system back is logged as closed',
      (tester) async {
    final before = _logs();
    await _openScanner(tester);

    await tester.binding.handlePopRoute(); // Android back button
    final log = await _newLog(tester, before);

    expect(log['frame'], isNull);
    final events = _events(log);
    expect(events.first, 'start');
    expect(events, contains('detect'));
    expect(events.last, 'closed');
  });
}
