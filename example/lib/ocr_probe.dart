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
  for (final name in ['new_plate_ebr.png']) {
    final data = await rootBundle.load('assets/samples/$name');
    final file = File('${Directory.systemTemp.path}/$name');
    await file.writeAsBytes(data.buffer.asUint8List());

    final frame = await PlateReader.recognizeImage(file.path);
    out.writeln('== $name');
    for (final l in frame.lines) {
      out.writeln('OCR "${l.text}" conf=${l.confidence?.toStringAsFixed(2)}');
    }
    out.writeln('CODE HINT ${frame.codeHint}');
    final candidate = await PlateReader.readImage(
      file.path,
      // The plate band in this sample (excludes the headline and logo).
      region: const NormalizedRect(0, 0.27, 1, 0.53),
    );
    out.writeln('PARSED $candidate');
  }
  debugPrint(out.toString());
  runApp(
    MaterialApp(
      home: Scaffold(body: SafeArea(child: Text('$out'))),
    ),
  );
}
