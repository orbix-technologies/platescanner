import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'controller_test.dart' show plateOcr;
import 'fake_plate_service.dart';

void main() {
  test('a session writes its log and frame beside the captured still',
      () async {
    final dir = await Directory.systemTemp.createTemp('et_plate_log_test');
    final frame = File('${dir.path}/et_plate_1.jpg')..writeAsBytesSync([1, 2]);
    final fake = FakePlateService()
      ..areaOcr = plateOcr
      ..framePath = frame.path;
    final c = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      recordSessions: true,
    );
    await c.initialize();
    await c.startSession();
    fake.emitLines(['D-0123456']);
    await Future<void>.delayed(Duration.zero);
    await c.captureArea();
    await c.confirmArea();
    await c.confirm();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final logs = Directory('${dir.path}/et_plate_logs').listSync();
    final json =
        logs.whereType<File>().firstWhere((f) => f.path.endsWith('.json'));
    expect(logs.any((f) => f.path.endsWith('.jpg')), isTrue);

    final log = jsonDecode(json.readAsStringSync()) as Map<String, Object?>;
    final events =
        (log['events'] as List).map((e) => (e as Map)['event']).toList();
    expect(
        events,
        containsAllInOrder(
          [
            'start',
            'detect',
            'capture',
            'confirmArea',
            'areaOcr',
            'arranged',
            'done'
          ],
        ));
    final arranged = (log['events'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((e) => e['event'] == 'arranged');
    expect(arranged['layout'], '1 XX 0123456 AA');

    c.dispose();
    await dir.delete(recursive: true);
  });
}
