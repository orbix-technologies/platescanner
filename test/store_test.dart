import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/persistence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

PlateRecord record(String id, String serial, {int minute = 0}) => PlateRecord(
      id: id,
      code: '2',
      regionCode: 'AA',
      serial: serial,
      layout: PlateLayout.singleRow,
      rawText: '2 AA $serial',
      confidence: 0.9,
      capturedAt: DateTime(2026, 10, 15, 9, minute),
      location: const PlateLocation(latitude: 9.03, longitude: 38.74),
    );

void main() {
  sqfliteFfiInit();
  late SqlitePlateRecordStore store;

  setUp(() async {
    store = SqlitePlateRecordStore(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    await store.initialize();
  });

  tearDown(() => store.close());

  test('save / get round-trip', () async {
    await store.save(record('a', 'A12345'));
    final r = await store.get('a');
    expect(r!.canonical, '2-AA-A12345');
    expect(r.location!.latitude, 9.03);
    expect(r.layout, PlateLayout.singleRow);
  });

  test('getAll is newest first', () async {
    await store.save(record('a', '11111', minute: 1));
    await store.save(record('b', '22222', minute: 2));
    expect((await store.getAll()).map((r) => r.id), ['b', 'a']);
  });

  test('findBySerial, updateStatus, delete', () async {
    await store.save(record('a', '11111'));
    await store.save(record('b', '11111', minute: 3));
    expect(await store.findBySerial('11111', regionCode: 'AA'), hasLength(2));
    expect(await store.findBySerial('11111', regionCode: 'OR'), isEmpty);

    await store.updateStatus('a', 'reported');
    expect((await store.get('a'))!.status, 'reported');

    await store.delete('a');
    expect(await store.get('a'), isNull);
  });

  test('json round-trip', () {
    final r = record('a', 'A12345');
    final back = PlateRecord.fromJson(r.toJson());
    expect(back.canonical, r.canonical);
    expect(back.location!.longitude, 38.74);
  });
}
