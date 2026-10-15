/// Optional SQLite persistence for [PlateRecord]s.
library;

export 'src/models/plate_record.dart' show PlateRecord, PlateLocation;
export 'src/persistence/plate_record_store.dart';
export 'src/persistence/sqlite_plate_record_store.dart';
