/// Category of a [PlateReaderException].
enum PlateReaderErrorCode {
  /// Camera permission was denied.
  permissionDenied,

  /// No usable camera, or it failed to open.
  cameraUnavailable,

  /// The on-device recognition model could not be loaded.
  modelLoadFailed,

  /// Platform or device is not supported.
  unsupportedDevice,

  /// A platform channel call failed.
  channelError,

  /// Operation is not valid in the current [ScanPhase].
  invalidState,
}

/// Typed errors thrown by the plate reader package.
class PlateReaderException implements Exception {
  /// Creates an exception with a user-facing [message].
  PlateReaderException(this.code, this.message, {this.cause});

  /// Error category.
  final PlateReaderErrorCode code;

  /// Human-readable error description.
  final String message;

  /// Optional underlying error.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'PlateReaderException(${code.name}): $message'
      : 'PlateReaderException(${code.name}): $message ($cause)';
}
