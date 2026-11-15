/// What the browser deletes when the user resets a web database that won't
/// open (#793).
///
/// An interface on the VM-compilable side of this package, so that
/// `WebPlatformBootstrap` can hold one without reaching `dart:js_interop`.
/// The implementation, over the browser's IndexedDB and OPFS, lives in
/// `web_storage_composition.dart`.
abstract interface class WebStorageReset {
  /// Whether [error] is a failure this reset could fix.
  ///
  /// Only those count toward the failure screen's reset offer; a network
  /// failure, say, would be the same after the data was gone.
  bool answers(Object error);

  /// Deletes every server database the browser holds for this origin.
  ///
  /// Throws `LocalDataInUseError` when another tab or window holds one open
  /// and the delete could not complete. A delete the browser reports blocked
  /// stays queued there, and an open of that database would wait behind it
  /// until the other connections close, so `WebPlatformBootstrap` calls this
  /// again before its next open.
  Future<void> deleteAll();
}
