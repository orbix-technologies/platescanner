import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/plate_record.dart';
import 'plate_record_store.dart';

/// [PlateRecordStore] backed by `sqflite`.
class SqlitePlateRecordStore implements PlateRecordStore {
  /// Creates a store.
  ///
  /// [databasePath] defaults to `et_plate_reader.db` in the sqflite
  /// databases directory. Pass [factory] (e.g. `databaseFactoryFfi`) in tests.
  SqlitePlateRecordStore({String? databasePath, DatabaseFactory? factory})
      : _databasePath = databasePath,
        _factory = factory;

  static const _table = 'plates';
  static const _version = 1;

  final String? _databasePath;
  final DatabaseFactory? _factory;
  Database? _db;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('SqlitePlateRecordStore.initialize() not called');
    }
    return db;
  }

  @override
  Future<void> initialize() async {
    if (_db != null) return;
    final factory = _factory ?? databaseFactory;
    final path = _databasePath ??
        p.join(await factory.getDatabasesPath(), 'et_plate_reader.db');
    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_table (
        id TEXT PRIMARY KEY,
        code TEXT NOT NULL,
        region_code TEXT,
        serial TEXT NOT NULL,
        layout TEXT NOT NULL,
        raw_text TEXT NOT NULL,
        confidence REAL NOT NULL,
        captured_at INTEGER NOT NULL,
        edited_by_user INTEGER NOT NULL DEFAULT 0,
        image_path TEXT,
        latitude REAL,
        longitude REAL,
        accuracy_meters REAL,
        description TEXT,
        status TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_plates_serial ON $_table (serial)');
    await db.execute(
      'CREATE INDEX idx_plates_captured_at ON $_table (captured_at)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Add migrations here as `if (oldVersion < N) { ... }`.
  }

  @override
  Future<void> save(PlateRecord record) async {
    await _database.insert(
      _table,
      _toRow(record),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<PlateRecord?> get(String id) async {
    final rows = await _database.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<List<PlateRecord>> getAll() async {
    final rows = await _database.query(_table, orderBy: 'captured_at DESC');
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<PlateRecord>> findBySerial(
    String serial, {
    String? regionCode,
  }) async {
    final rows = await _database.query(
      _table,
      where:
          regionCode == null ? 'serial = ?' : 'serial = ? AND region_code = ?',
      whereArgs: regionCode == null ? [serial] : [serial, regionCode],
      orderBy: 'captured_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> delete(String id) async {
    await _database.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> updateStatus(String id, String status) async {
    await _database.update(
      _table,
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Map<String, Object?> _toRow(PlateRecord r) => {
        'id': r.id,
        'code': r.code,
        'region_code': r.regionCode,
        'serial': r.serial,
        'layout': r.layout.name,
        'raw_text': r.rawText,
        'confidence': r.confidence,
        'captured_at': r.capturedAt.millisecondsSinceEpoch,
        'edited_by_user': r.editedByUser ? 1 : 0,
        'image_path': r.imagePath,
        'latitude': r.location?.latitude,
        'longitude': r.location?.longitude,
        'accuracy_meters': r.location?.accuracyMeters,
        'description': r.description,
        'status': r.status,
      };

  PlateRecord _fromRow(Map<String, Object?> row) {
    final lat = row['latitude'] as num?;
    final lng = row['longitude'] as num?;
    return PlateRecord(
      id: row['id'] as String,
      code: row['code'] as String,
      regionCode: row['region_code'] as String?,
      serial: row['serial'] as String,
      layout: PlateLayout.values.firstWhere(
        (l) => l.name == row['layout'],
        orElse: () => PlateLayout.unknown,
      ),
      rawText: row['raw_text'] as String,
      confidence: (row['confidence'] as num).toDouble(),
      capturedAt: DateTime.fromMillisecondsSinceEpoch(
        row['captured_at'] as int,
      ),
      editedByUser: (row['edited_by_user'] as int? ?? 0) == 1,
      imagePath: row['image_path'] as String?,
      location: lat == null || lng == null
          ? null
          : PlateLocation(
              latitude: lat.toDouble(),
              longitude: lng.toDouble(),
              accuracyMeters: (row['accuracy_meters'] as num?)?.toDouble(),
            ),
      description: row['description'] as String?,
      status: row['status'] as String,
    );
  }
}
