// On-device probe: re-reads every logged patrol vehicle photo with the
// current PatrolRefiner and writes what each step found.
//
// flutter build apk --debug -t lib/patrol_probe.dart, install, open; results
// go to cache/et_plate_logs/refine_probe.json.
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: _Probe()));

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  String _status = 'starting';

  @override
  void initState() {
    super.initState();
    _run();
  }

  NormalizedRect _r(Map m) => NormalizedRect(
      (m['left'] as num).toDouble(),
      (m['top'] as num).toDouble(),
      (m['right'] as num).toDouble(),
      (m['bottom'] as num).toDouble());

  Future<void> _run() async {
    // This app's cache folder (the logs store absolute photo paths there).
    final dir = Directory(
        '/data/user/0/com.et_plate_reader.et_plate_reader_example/cache/et_plate_logs');
    final logs = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('patrol_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final refiner = PatrolRefiner(PlateRecognitionServiceFactory.create());
    // Resumes: results so far are kept, their photos skipped.
    final file = File('${dir.path}/refine_probe.json');
    final out = file.existsSync()
        ? (jsonDecode(file.readAsStringSync()) as List)
            .cast<Map<String, Object?>>()
        : <Map<String, Object?>>[];
    final seen = {for (final o in out) '${o['patrol']}/${o['photo']}'};
    var done = out.length;
    for (final f in logs) {
      final log = jsonDecode(f.readAsStringSync()) as Map;
      for (final v in (log['vehicles'] as List).cast<Map>()) {
        final photo = v['photo'] as String?;
        if (photo == null || v['box'] == null || !File(photo).existsSync()) {
          continue;
        }
        if (seen
            .contains('${f.uri.pathSegments.last}/${photo.split('/').last}')) {
          continue;
        }
        final plate = v['plate'] as String;
        final serial = plate.split('-').last;
        final trace = RefineTrace();
        final sw = Stopwatch()..start();
        try {
          await refiner.refine(photo, serial, _r(v['box'] as Map),
              trace: trace);
        } catch (e) {
          trace.failure = 'error: $e';
        }
        out.add({
          'patrol': f.uri.pathSegments.last,
          'plate': plate,
          'votes': v['votes'],
          'photo': photo.split('/').last,
          'ms': sw.elapsedMilliseconds,
          ...trace.toJson(),
        });
        done++;
        file.writeAsStringSync(jsonEncode(out));
        if (mounted) setState(() => _status = '$done');
      }
    }
    File('${dir.path}/refine_probe.json').writeAsStringSync(jsonEncode(out));
    debugPrint('PROBE DONE $done');
    await _scans(dir, refiner);
    if (mounted) setState(() => _status = 'done $done');
  }

  /// The same re-read on the one-photo scans the user confirmed with Done:
  /// full-resolution photos with a known code, region and number.
  Future<void> _scans(Directory dir, PatrolRefiner refiner) async {
    final file = File('${dir.path}/refine_probe_scans.json');
    final out = file.existsSync()
        ? (jsonDecode(file.readAsStringSync()) as List)
            .cast<Map<String, Object?>>()
        : <Map<String, Object?>>[];
    final seen = {for (final o in out) o['session']};
    final sessions = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('session_') && f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in sessions) {
      final id = f.uri.pathSegments.last;
      if (seen.contains(id)) continue;
      final log = jsonDecode(f.readAsStringSync()) as Map;
      final events = (log['events'] as List).cast<Map>();
      final done = events.where((e) => e['event'] == 'done').lastOrNull;
      final cap = events.where((e) => e['event'] == 'capture').lastOrNull;
      final jpg = f.path.replaceAll('.json', '.jpg');
      if (done == null || cap == null || !File(jpg).existsSync()) continue;
      final record = done['record'] as String?;
      if (record == null) continue;
      final serial = record.split('-').last;
      final box = (cap['detected'] ?? cap['proposed']) as Map?;
      if (box == null) continue;
      final trace = RefineTrace();
      final sw = Stopwatch()..start();
      try {
        await refiner.refine(jpg, serial, _r(box), trace: trace);
      } catch (e) {
        trace.failure = 'error: $e';
      }
      out.add({
        'session': id,
        'expected': record,
        'edited': done['editedByUser'],
        'ms': sw.elapsedMilliseconds,
        ...trace.toJson(),
      });
      file.writeAsStringSync(jsonEncode(out));
      if (mounted) setState(() => _status = 'scans ${out.length}');
    }
    debugPrint('PROBE SCANS DONE ${out.length}');
    if (mounted) setState(() => _status = 'all done');
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('Refine probe: $_status')));
}
