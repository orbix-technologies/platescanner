import 'dart:io';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Diagnostic entry point: runs the on-device OCR pipeline on the bundled
/// sample images and prints raw lines, the code hint and the parsed reading.
///
/// `flutter run -t lib/ocr_probe.dart`
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final out = StringBuffer();
  // Every image dropped into assets/samples/.
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final samples = manifest
      .listAssets()
      .where((a) => a.startsWith('assets/samples/'))
      .map((a) => a.substring('assets/samples/'.length))
      .toList();
  for (final name in samples) {
    final data = await rootBundle.load('assets/samples/$name');
    final file = File('${Directory.systemTemp.path}/$name');
    await file.writeAsBytes(data.buffer.asUint8List());

    final frame = await PlateReader.recognizeImage(file.path);
    out.writeln('== $name');
    for (final l in frame.lines) {
      out.writeln('OCR "${l.text}" conf=${l.confidence?.toStringAsFixed(2)}');
    }
    out.writeln('CODE HINT ${frame.codeHint}');
    // Steps 1–4 as the scanner runs them: detect the area, then read it.
    final area = const PlateAreaDetector().detect(frame.lines) ??
        const NormalizedRect(0, 0, 1, 1);
    out.writeln('AREA $area');
    final ocr = await PlateReader.recognizeArea(file.path, area);
    for (final e in ocr.elements) {
      out.writeln('ELEMENT "${e.text}" symbols=${e.symbols.map((s) => s.text).join()}');
    }
    out.writeln('AREA CODE HINT ${ocr.codeHint}');
    final arranged = const PlateArranger().arrange(ocr);
    out.writeln('ARRANGED ${arranged.arrangement.layoutText}');
    for (final section in arranged.arrangement.sections) {
      out.writeln('  ${section.kind.index + 1} ${section.kind.name}: '
          '"${section.value}" chars=${section.chars} '
          '${section.detected ? '' : '(not detected)'}');
    }
    out.writeln('  ignored: ${arranged.arrangement.ignored}');
    out.writeln('CANDIDATE ${arranged.candidate}');
  }
  debugPrint(out.toString());
  runApp(
    MaterialApp(
      home: Scaffold(body: SafeArea(child: Text('$out'))),
    ),
  );
}
