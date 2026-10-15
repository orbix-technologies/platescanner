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

  Future<void> _scan({bool customOverlay = false}) async {
    final controller = PlateReaderController();
    final record = await Navigator.of(context).push<PlateRecord>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: PlateScannerView(
            controller: controller,
            overlayBuilder: customOverlay ? _minimalOverlay : null,
            onPlateConfirmed: (r) => Navigator.pop(context, r),
            onCancel: () => Navigator.pop(context),
            onError: (e) => debugPrint('Plate reader error: $e'),
          ),
        ),
      ),
    );
    controller.dispose();
    if (record == null || !mounted) return;

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

  /// Host-built HUD: shows how [PlateScannerOverlayBuilder] replaces the
  /// default. One button per step; the view still draws the frame and area.
  Widget _minimalOverlay(BuildContext context, PlateReaderController c) {
    final (label, action) = switch (c.phase) {
      ScanPhase.detecting => (
          c.detectedArea == null ? 'Point at a plate' : 'Capture',
          c.captureArea,
        ),
      ScanPhase.confirmingArea => ('Confirm area', c.confirmArea),
      ScanPhase.reading => ('Reading…', null),
      ScanPhase.review when c.canConfirm => (
          'Use ${c.arrangement?.layoutText}',
          () async {
            final navigator = Navigator.of(context);
            navigator.pop(await c.confirm());
          },
        ),
      ScanPhase.review || ScanPhase.error => ('Retake', c.retake),
      _ => ('…', null),
    };
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FilledButton(onPressed: action, child: Text(label)),
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
        onPressed: supported ? _scan : null,
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Scan plate'),
      ),
      body: Column(
        children: [
          if (availability != null && !supported)
            MaterialBanner(
              content: Text(availability.message ?? 'Not supported'),
              actions: [TextButton(onPressed: _load, child: const Text('Retry'))],
            ),
          if (supported)
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Scan with a custom overlay'),
              onTap: () => _scan(customOverlay: true),
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
                            TimeOfDay.fromDateTime(r.capturedAt).format(context),
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
