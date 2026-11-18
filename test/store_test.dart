import 'dart:io';

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

  PlateRecord diplomatic(String id, String embassy) => PlateRecord(
        id: id,
        code: 'CD',
        regionCode: null,
        serial: '0123',
        layout: PlateLayout.singleRow,
        rawText: '$embassy ኮዲ 0123 CD',
        confidence: 0.9,
        capturedAt: DateTime(2026, 10, 27, 11),
        embassyCode: embassy,
      );

  test('diplomatic: the embassy number is kept and tells the country',
      () async {
    await store.save(diplomatic('a', '132'));
    await store.save(diplomatic('b', '01'));
    final a = await store.get('a'), b = await store.get('b');
    // Two embassies' cars with the same number stay apart.
    expect(a!.canonical, 'CD-132-0123');
    expect(b!.canonical, 'CD-01-0123');
    expect(a.mission, 'Armenia');
    expect(b.mission, 'Italy');
    expect(PlateRecord.fromJson(a.toJson()).embassyCode, '132');
    expect(const EthiopianPlateParser().format(a), 'CD · 132 · 0123');
  });

  test('a version 1 database gets the embassy column', () async {
    final path = '${Directory.systemTemp.createTempSync().path}/v1.db';
    final v1 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => db.execute('''
            CREATE TABLE plates (
              id TEXT PRIMARY KEY, code TEXT NOT NULL, region_code TEXT,
              serial TEXT NOT NULL, layout TEXT NOT NULL,
              raw_text TEXT NOT NULL, confidence REAL NOT NULL,
              captured_at INTEGER NOT NULL,
              edited_by_user INTEGER NOT NULL DEFAULT 0, image_path TEXT,
              latitude REAL, longitude REAL, accuracy_meters REAL,
              description TEXT, status TEXT NOT NULL)'''),
        ));
    await v1.insert('plates', {
      'id': 'old',
      'code': '2',
      'region_code': 'AA',
      'serial': 'A12345',
      'layout': 'singleRow',
      'raw_text': '',
      'confidence': 0.9,
      'captured_at': 0,
      'status': 'confirmed',
    });
    await v1.close();
    final upgraded =
        SqlitePlateRecordStore(databasePath: path, factory: databaseFactoryFfi);
    await upgraded.initialize();
    expect((await upgraded.get('old'))!.canonical, '2-AA-A12345');
    await upgraded.save(diplomatic('new', '132'));
    expect((await upgraded.get('new'))!.embassyCode, '132');
    await upgraded.close();
  });
}
