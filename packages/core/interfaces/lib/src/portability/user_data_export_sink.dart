import 'dart:typed_data';

/// What became of a [UserDataExportSink.save] that did not fail.
enum UserDataExportSaveResult {
  /// The bytes were written to a location the user chose.
  saved,

  /// The browser was handed the file as a download. A browser reports neither
  /// where the file went nor whether the user kept it, so this is as much as
  /// a download can say.
  downloaded,

  /// The user closed the save dialog without choosing a location. Not a
  /// failure: nothing was written, and nothing went wrong.
  cancelled,
}

/// Puts a finished export bundle (#92) into a file the user can keep.
///
/// One implementation per platform family: a native save dialog, and a browser
/// download. The export screen (#93) depends on this and on neither.
abstract interface class UserDataExportSink {
  /// Saves [bytes] as [fileName].
  ///
  /// Throws when the file could not be written or offered; a user who backs
  /// out of a dialog is [UserDataExportSaveResult.cancelled], not an error.
  Future<UserDataExportSaveResult> save({
    required String fileName,
    required Uint8List bytes,
  });
}
