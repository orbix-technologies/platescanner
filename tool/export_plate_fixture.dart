// Saves a logged session's confirmed plate area as a small PNG fixture.
//
// dart run tool/export_plate_fixture.dart <session.json> <out.png>
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final log = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final ca = (log['events'] as List)
      .cast<Map<String, dynamic>>()
      .lastWhere((e) => e['event'] == 'confirmArea');
  final photo = img.decodeJpg(File(args[0].replaceAll('.json', '.jpg')).readAsBytesSync())!;
  final a = (ca['area'] as Map).cast<String, num>();
  final crop = img.copyCrop(
    photo,
    x: (a['left']! * photo.width).round(),
    y: (a['top']! * photo.height).round(),
    width: ((a['right']! - a['left']!) * photo.width).round(),
    height: ((a['bottom']! - a['top']!) * photo.height).round(),
  );
  File(args[1]).writeAsBytesSync(img.encodePng(img.copyResize(crop, height: 160)));
}
