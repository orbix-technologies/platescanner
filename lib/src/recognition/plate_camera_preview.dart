import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'channel_plate_recognition_service.dart';
import 'plate_recognition_service.dart';

/// Native camera preview (CameraX `PreviewView` / `AVCaptureVideoPreviewLayer`).
class PlateCameraPreview extends StatefulWidget {
  /// Creates the preview bound to [service].
  const PlateCameraPreview({
    super.key,
    required this.service,
    this.patrol = false,
  });

  /// Service that receives this view's id.
  final PlateRecognitionService service;

  /// Patrol camera settings: larger frames and a short, steady exposure for
  /// plates passing by (Android).
  final bool patrol;

  @override
  State<PlateCameraPreview> createState() => _PlateCameraPreviewState();
}

class _PlateCameraPreviewState extends State<PlateCameraPreview> {
  int? _viewId;

  void _onCreated(int id) {
    _viewId = id;
    final s = widget.service;
    if (s is ChannelPlateRecognitionService) s.attach(id);
  }

  @override
  void dispose() {
    final s = widget.service;
    if (s is ChannelPlateRecognitionService) s.detach(_viewId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const viewType = ChannelPlateRecognitionService.viewType;
    final gestures = <Factory<OneSequenceGestureRecognizer>>{};
    if (!kIsWeb && Platform.isAndroid) {
      return AndroidView(
        viewType: viewType,
        onPlatformViewCreated: _onCreated,
        gestureRecognizers: gestures,
        creationParams: {'patrol': widget.patrol},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (!kIsWeb && Platform.isIOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: _onCreated,
        gestureRecognizers: gestures,
        creationParams: {'patrol': widget.patrol},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return const Center(
      child: Text('Plate reading is only supported on Android and iOS.'),
    );
  }
}
