import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/persistence.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'record_detail.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plate reader',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFF5C518)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _store = SqlitePlateRecordStore();
  final _parser = const EthiopianPlateParser();
  PlateReaderAvailability? _availability;
  List<PlateRecord> _history = const [];
  Future<void> _saving = Future.value();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Camera-free preflight — gate the Scan button before opening the camera.
    final availability = await PlateReader.checkAvailability();
    await _store.initialize();
    final history = await _store.getAll();
    if (!mounted) return;
    setState(() {
      _availability = availability;
      _history = history;
    });
  }

  Future<void> _scan({bool quick = false}) async {
    final result = await EtPlateReader.scan(
      context,
      // Test app: keep the scan logs in release builds too.
      recordSessions: true,
      // Quick: Amharic texts, no confirm step, no review for valid plates.
      strings: quick ? const PlateScannerStrings.am() : null,
      options: quick
          ? const PlateScannerOptions(
              confirmArea: ConfirmAreaMode.never,
              showReview: false,
            )
          : const PlateScannerOptions(),
    );
    if (result == null || !mounted) return;
    final record = result.record;

    final seen = await _store.findBySerial(
      record.serial,
      regionCode: record.regionCode,
    );
    await _save(record);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          seen.isEmpty
              ? 'Saved ${_parser.format(record)}'
              : '${_parser.format(record)} was already read ${seen.length}×',
        ),
      ),
    );
  }

  Future<void> _patrol() async {
    final vehicles = await EtPlateReader.patrol(
      context,
      recordSessions: true,
      // Saved as each vehicle passes (and again when its photo is read in
      // full), so closing the patrol or a crash mid-walk loses nothing.
      onVehicle: (v) => _save(v.toRecord()),
      // A misread seen as a second vehicle, merged into the first.
      onVehicleRemoved: (v) => _remove(v.toRecord().id),
    );
    await _saving;
    if (vehicles == null || !mounted) return;
    final check = vehicles.where((v) => v.needsCheck).length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${vehicles.length} plates read'
            '${check == 0 ? '' : ', $check to check'}'),
      ),
    );
  }

  /// Saves [record] (replacing an earlier save of it), one at a time, with
  /// its photo kept.
  Future<void> _save(PlateRecord record) => _saving = _saving.then((_) async {
        try {
          final kept = await _keepPhoto(record);
          await _store.save(kept);
          final history = await _store.getAll();
          if (mounted) setState(() => _history = history);
        } catch (e) {
          debugPrint('Saving ${record.serial} failed: $e');
        }
      });

  /// Deletes the record [id] and its kept photo, after earlier saves.
  Future<void> _remove(String id) => _saving = _saving.then((_) async {
        try {
          final r = _history.where((h) => h.id == id).firstOrNull;
          await _store.delete(id);
          _deletePhoto(r?.imagePath);
          final history = await _store.getAll();
          if (mounted) setState(() => _history = history);
        } catch (e) {
          debugPrint('Removing $id failed: $e');
        }
      });

  /// The photo is in the cache, which Android may clear: copied into the
  /// app's documents, replacing an earlier photo of the same record.
  Future<PlateRecord> _keepPhoto(PlateRecord r) async {
    final path = r.imagePath;
    if (path == null) return r;
    final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/plate_photos');
    if (path.startsWith(dir.path)) return r;
    final src = File(path);
    if (!src.existsSync()) return r;
    await dir.create(recursive: true);
    final kept = await src.copy('${dir.path}/${path.split('/').last}');
    final before = _history.where((h) => h.id == r.id).firstOrNull?.imagePath;
    if (before != null && before != kept.path) _deletePhoto(before);
    return r.copyWith(imagePath: kept.path);
  }

  /// Deletes a photo kept by [_keepPhoto].
  void _deletePhoto(String? path) {
    if (path == null || !path.contains('/plate_photos/')) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    _store.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availability = _availability;
    final supported = availability?.isSupported ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Ethiopian plate reader')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: supported ? () => _scan() : null,
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Scan plate'),
      ),
      body: Column(
        children: [
          if (availability != null && !supported)
            MaterialBanner(
              content: Text(availability.message ?? 'Not supported'),
              actions: [
                TextButton(onPressed: _load, child: const Text('Retry'))
              ],
            ),
          if (supported)
            ListTile(
              leading: const Icon(Icons.bolt),
              title: const Text('Quick scan (Amharic, no review)'),
              onTap: () => _scan(quick: true),
            ),
          if (supported)
            ListTile(
              leading: const Icon(Icons.directions_walk),
              title: const Text('Patrol (read plates while passing)'),
              onTap: _patrol,
            ),
          const Divider(height: 1),
          Expanded(
            child: _history.isEmpty
                ? const Center(child: Text('No plates read yet'))
                : ListView.builder(
                    itemCount: _history.length,
                    itemBuilder: (context, i) {
                      final r = _history[i];
                      return Dismissible(
                        key: ValueKey(r.id),
                        onDismissed: (_) async {
                          await _store.delete(r.id);
                          _deletePhoto(r.imagePath);
                          setState(() => _history = [..._history]..remove(r));
                        },
                        child: ListTile(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => RecordDetailPage(record: r),
                            ),
                          ),
                          title: Text(_parser.format(r)),
                          subtitle: Text(
                            '${r.serviceType?.label ?? r.code} · '
                            '${r.region?.englishName ?? 'no region'} · '
                            '${(r.confidence * 100).round()}%'
                            '${r.editedByUser ? ' · edited' : ''}'
                            '${r.status == 'check' ? ' · no plate seen' : ''}',
                          ),
                          trailing: Text(
                            TimeOfDay.fromDateTime(r.capturedAt)
                                .format(context),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
