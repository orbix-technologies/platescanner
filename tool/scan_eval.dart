// Scores the scanner's image steps on labelled scans: the area snapped to
// the plate (as the controller does after the photo) and the sections
// found in it, against what the plate really is.
//
// dart run tool/scan_eval.dart <dir with session_*.json/.jpg + labels.json>
//
// labels.json: {"<session id>": {"plate": "2-AA-C06703", "twoRow": false,
// "chars": 6}}. Every plate labelled has a code circle, a Ge'ez region
// (two letters) and a Latin region (two letters).
import 'dart:convert';
import 'dart:io';

import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';

void main(List<String> args) {
  final dir = args[0];
  final labels = (jsonDecode(File('$dir/labels.json').readAsStringSync())
          as Map<String, dynamic>)
      .cast<String, Map<String, dynamic>>();
  NormalizedRect? rect(Object? m) {
    if (m == null) return null;
    final a = (m as Map).cast<String, num>();
    return NormalizedRect(a['left']!.toDouble(), a['top']!.toDouble(),
        a['right']!.toDouble(), a['bottom']!.toDouble());
  }

  final checks = ['layout', 'number', 'code', 'geez', 'latin', 'all'];
  final ok = {for (final c in checks) c: 0};
  final perPlate = <String, List<int>>{};
  final ids = labels.keys.toList()..sort();
  for (final id in ids) {
    final want = labels[id]!;
    final json = File('$dir/session_$id.json');
    final jpg = '$dir/session_$id.jpg';
    if (!json.existsSync() || !File(jpg).existsSync()) continue;
    final events =
        ((jsonDecode(json.readAsStringSync()) as Map)['events'] as List)
            .cast<Map>();
    final cap = events.lastWhere((e) => e['event'] == 'capture');
    final proposed = rect(cap['proposed'])!;
    final detected = rect(cap['detected']);
    final snapped = snapCaptureAreaSync(jpg, proposed,
        fallback: detected == proposed ? null : detected);
    final area = snapped ?? proposed;
    final s = segmentCaptureSync(jpg, area);
    final r = {
      'layout': s != null && s.twoRow == want['twoRow'],
      'number': s != null && s.numberChars.length == want['chars'],
      'code': s?.code != null,
      'geez': s?.geezStack.length == 2,
      'latin': s?.latinStack.length == 2,
    };
    r['all'] = r.values.every((v) => v);
    r.forEach((k, v) => ok[k] = ok[k]! + (v ? 1 : 0));
    final plate = want['plate'] as String;
    final p = perPlate.putIfAbsent(plate, () => [0, 0]);
    p[1]++;
    if (r['all']!) p[0]++;
    stdout.writeln('${r['all']! ? 'ok ' : 'BAD'} $id ${plate.padRight(12)} '
        '${snapped == null ? 'no-snap' : 'snap   '} '
        'n=${s?.numberChars.length} two=${s?.twoRow} code=${s?.code != null} '
        'gz=${s?.geezStack.length} lat=${s?.latinStack.length} '
        '${(s?.notes ?? const []).where((n) => !n.startsWith('image=') && !n.startsWith('adaptive')).join(' ')}');
  }
  stdout.writeln();
  for (final c in checks) {
    stdout.writeln('${c.padRight(7)} ${ok[c]}/${ids.length}');
  }
  stdout.writeln();
  perPlate
      .forEach((k, v) => stdout.writeln('${k.padRight(12)} ${v[0]}/${v[1]}'));
}
