import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:interfaces/portability.dart';
import 'package:observability/observability.dart';

/// Writes `bytes` under `fileName` through a save dialog, and returns where
/// the file went, or null when the user closed the dialog.
///
/// Public only because the sink's constructor takes one; the package does
/// not export it.
typedef SaveExportFile = Future<Uri?> Function({
  required String fileName,
  required Uint8List bytes,
});

/// Saves an export bundle (#92) through the platform's save dialog, by way of
/// `file_picker`.
///
/// The plugin writes the bytes itself on every platform: on macOS, Windows
/// and Linux to the chosen path, and on Android through the chosen document's
/// content URI. On iOS it first stages them in the app's temporary directory,
/// under `tmp/flutter_file_picker/<uuid>/<file name>`, and exports that file
/// through the system's document picker, and it never deletes the staged
/// copy, whether the user saved or cancelled. The copy is the user's data in
/// a place they did not put it, so after every save, cancel or failure this
/// sink asks the plugin to clear its temporary files. Off iOS nothing is
/// staged and the default clean-up does nothing. A clean-up that fails is
/// logged and never changes the save's outcome.
///
/// `saveFile` and `clearTemporaryFiles` are the seams over the plugin, which
/// cannot run in a test; the defaults are the only code here that touches it.
class FilePickerUserDataExportSink implements UserDataExportSink {
  const FilePickerUserDataExportSink({
    SaveExportFile? saveFile,
    Future<void> Function()? clearTemporaryFiles,
  }) : _saveFile = saveFile ?? _saveWithFilePicker,
       _clearTemporaryFiles =
           clearTemporaryFiles ?? _clearFilePickerTemporaryFiles;

  static final BgeLogger _logger = BgeLogger(
    'bge.platform.native.data_export',
  );

  final SaveExportFile _saveFile;
  final Future<void> Function() _clearTemporaryFiles;

  @override
  Future<UserDataExportSaveResult> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final Uri? location;
    try {
      location = await _saveFile(fileName: fileName, bytes: bytes);
    } finally {
      await _clearQuietly();
    }
    return location == null
        ? UserDataExportSaveResult.cancelled
        : UserDataExportSaveResult.saved;
  }

  Future<void> _clearQuietly() async {
    try {
      await _clearTemporaryFiles();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        "Could not clear the file picker's temporary files after an export",
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

Future<Uri?> _saveWithFilePicker({
  required String fileName,
  required Uint8List bytes,
}) => FilePicker.saveFile(
  fileName: fileName,
  bytes: bytes,
  mimeType: 'application/json',
);

// Only iOS stages the export. On Android `clear` deletes the plugin's cache
// of *picked* files, which a save never writes; macOS answers it with
// nothing, and Windows and Linux do not implement it.
Future<void> _clearFilePickerTemporaryFiles() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return;
  await FilePicker.clearTemporaryFiles();
}
