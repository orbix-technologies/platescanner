import 'dart:io';
import 'dart:ui' as ui;

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';

/// One saved reading: the photo it was read from, with the plate area and
/// each section's box drawn, to check what was read and what was missed.
class RecordDetailPage extends StatelessWidget {
  const RecordDetailPage({super.key, required this.record});

  final PlateRecord record;

  static const sectionColors = {
    'code': Color(0xFF42A5F5),
    'geezRegion': Color(0xFFAB47BC),
    'number': Color(0xFFFFCA28),
    'latinRegion': Color(0xFF66BB6A),
  };

  static const sectionNames = {
    'code': 'Code',
    'geezRegion': "Ge'ez region",
    'number': 'Number',
    'latinRegion': 'Region',
  };

  @override
  Widget build(BuildContext context) {
    final r = record;
    final path = r.imagePath;
    final hasPhoto = path != null && File(path).existsSync();
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(r.canonical)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            [r.code, r.regionCode ?? '–', r.serial].join('  ·  '),
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '${r.serviceType?.label ?? r.code} · '
            '${r.region?.englishName ?? 'no region'} · '
            '${r.layout.name} · ${(r.confidence * 100).round()}%'
            '${r.editedByUser ? ' · edited' : ''}'
            '${r.status == 'check' ? ' · no plate outline found' : ''}',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (!hasPhoto)
            const Text('No photo was saved with this reading.')
          else
            FutureBuilder<Size>(
              future: _imageSize(path),
              builder: (context, snap) {
                final size = snap.data;
                if (size == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (r.plateArea != null) ...[
                      Text('Plate area', style: text.titleSmall),
                      const SizedBox(height: 6),
                      _Zoomed(
                        path: path,
                        image: size,
                        area: _padded(r.plateArea!),
                        plate: r.plateArea!,
                        sections: r.sectionAreas,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          for (final e in sectionNames.entries)
                            _Legend(
                              color: sectionColors[e.key]!,
                              label: e.value,
                              found: r.sectionAreas.containsKey(e.key),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ] else
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('The plate area was not recorded.'),
                      ),
                    Text('Whole photo (pinch to zoom)', style: text.titleSmall),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: InteractiveViewer(
                        maxScale: 8,
                        child: AspectRatio(
                          aspectRatio: size.width / size.height,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.file(File(path), fit: BoxFit.fill),
                              CustomPaint(
                                painter: _Boxes(
                                  view: const NormalizedRect(0, 0, 1, 1),
                                  plate: r.plateArea,
                                  sections: r.sectionAreas,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${size.width.round()} × ${size.height.round()} px'
                      '${r.plateArea == null ? '' : ' · plate '
                          '${(r.plateArea!.width * size.width).round()} × '
                          '${(r.plateArea!.height * size.height).round()} px'}',
                      style: text.bodySmall,
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  /// The plate area with some of its surroundings.
  static NormalizedRect _padded(NormalizedRect a) {
    final dx = a.width * 0.25, dy = a.height * 0.6;
    double c(double v) => v.clamp(0.0, 1.0);
    return NormalizedRect(
        c(a.left - dx), c(a.top - dy), c(a.right + dx), c(a.bottom + dy));
  }

  static Future<Size> _imageSize(String path) async {
    final codec =
        await ui.instantiateImageCodec(await File(path).readAsBytes());
    final frame = await codec.getNextFrame();
    return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  }
}

/// [area] of the photo, enlarged, with the boxes drawn.
class _Zoomed extends StatelessWidget {
  const _Zoomed({
    required this.path,
    required this.image,
    required this.area,
    required this.plate,
    required this.sections,
  });

  final String path;
  final Size image;
  final NormalizedRect area, plate;
  final Map<String, NormalizedRect> sections;

  @override
  Widget build(BuildContext context) {
    final aspect = (area.width * image.width) / (area.height * image.height);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (context, c) {
            final fullW = c.maxWidth / area.width;
            final fullH = c.maxHeight / area.height;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: -area.left * fullW,
                  top: -area.top * fullH,
                  width: fullW,
                  height: fullH,
                  child: Image.file(File(path), fit: BoxFit.fill),
                ),
                CustomPaint(
                  painter: _Boxes(view: area, plate: plate, sections: sections),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The plate area (white) and each section's box, in [view]'s coordinates.
class _Boxes extends CustomPainter {
  _Boxes({required this.view, this.plate, required this.sections});

  final NormalizedRect view;
  final NormalizedRect? plate;
  final Map<String, NormalizedRect> sections;

  Rect _toView(NormalizedRect r, Size size) => Rect.fromLTRB(
        (r.left - view.left) / view.width * size.width,
        (r.top - view.top) / view.height * size.height,
        (r.right - view.left) / view.width * size.width,
        (r.bottom - view.top) / view.height * size.height,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final p = plate;
    if (p != null) {
      canvas.drawRect(
        _toView(p, size),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (final e in sections.entries) {
      canvas.drawRect(
        _toView(e.value, size),
        Paint()
          ..color = RecordDetailPage.sectionColors[e.key] ?? Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_Boxes old) => true;
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.found,
  });

  final Color color;
  final String label;
  final bool found;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 2),
            ),
          ),
          const SizedBox(width: 4),
          Text(found ? label : '$label (not found)'),
        ],
      );
}
