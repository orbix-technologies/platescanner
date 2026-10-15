import '../models/plate_record.dart';

/// Persistence contract for plate records.
///
/// Hosts may implement this with Drift, Hive, Firebase, etc.
abstract class PlateRecordStore {
  /// Open / prepare the store (no-op for some backends).
  Future<void> initialize();

  /// Insert or replace a record.
  Future<void> save(PlateRecord record);

  /// Fetch a single record by [id], or `null` if missing.
  Future<PlateRecord?> get(String id);

  /// Fetch all stored records, newest first.
  Future<List<PlateRecord>> getAll();

  /// Records with the same [serial] (and [regionCode], when given), newest
  /// first — lets hosts flag a plate that was already read.
  Future<List<PlateRecord>> findBySerial(String serial, {String? regionCode});

  /// Delete a record.
  Future<void> delete(String id);

  /// Update only the status field.
  Future<void> updateStatus(String id, String status);

  /// Release resources.
  Future<void> close();
}
