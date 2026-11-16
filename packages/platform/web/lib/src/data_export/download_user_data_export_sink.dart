import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:interfaces/portability.dart';
import 'package:web/web.dart' as web;

/// Hands an export bundle (#92) to the browser as a file download.
///
/// A download cannot report a cancel, so [save] always reports
/// [UserDataExportSaveResult.downloaded]. It throws when the browser refuses
/// to build or click the link.
///
/// `click` and `revoke` are seams over the DOM; the defaults click a real
/// anchor and revoke through `URL.revokeObjectURL`.
class DownloadUserDataExportSink implements UserDataExportSink {
  DownloadUserDataExportSink({
    void Function(String url, String fileName)? click,
    void Function(String url)? revoke,
  }) : _click = click ?? _clickAnchor,
       _revoke = revoke ?? _revokeObjectUrl;

  /// How long the object URL outlives the click.
  ///
  /// The browser starts the download after `click()` returns, and WebKit
  /// cancels it when the URL is already gone (WebKit bug 211234; Firefox had
  /// the same in bug 1282407). Revoking at once would report a download that
  /// never arrives.
  static const Duration revokeDelay = Duration(seconds: 40);

  final void Function(String url, String fileName) _click;
  final void Function(String url) _revoke;

  @override
  Future<UserDataExportSaveResult> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'application/json'),
    );
    final url = web.URL.createObjectURL(blob);
    try {
      _click(url, fileName);
    } on Object {
      // Nothing is downloading, so nothing needs the URL to outlive this.
      _revoke(url);
      rethrow;
    }
    Timer(revokeDelay, () => _revoke(url));
    return UserDataExportSaveResult.downloaded;
  }
}

void _clickAnchor(String url, String fileName) {
  web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..click();
}

void _revokeObjectUrl(String url) => web.URL.revokeObjectURL(url);
