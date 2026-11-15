/// A `PlatformBootstrap.reset` could not delete the local data because
/// other windows or tabs hold it open (#793).
///
/// Closing them and trying again is the way on. The shell shows its own
/// message for this failure instead of the generic startup one.
final class LocalDataInUseError implements Exception {
  const LocalDataInUseError();

  @override
  String toString() =>
      'LocalDataInUseError: other windows or tabs hold the local data open';
}
