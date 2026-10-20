import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/persistence.dart';
import 'package:flutter/material.dart';

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
    await _store.save(record);
    final history = await _store.getAll();
    if (!mounted) return;
    setState(() => _history = history);
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
                          setState(() => _history = [..._history]..remove(r));
                        },
                        child: ListTile(
                          title: Text(_parser.format(r)),
                          subtitle: Text(
                            '${r.serviceType?.label ?? r.code} · '
                            '${r.region?.englishName ?? 'no region'} · '
                            '${(r.confidence * 100).round()}%'
                            '${r.editedByUser ? ' · edited' : ''}',
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
