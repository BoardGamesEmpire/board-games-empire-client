import 'package:web/web.dart' as web;
import 'package:web_platform/src/storage/persistent_storage_request.dart';

/// [PersistRefusals] in the browser's `localStorage` (#320).
///
/// Per origin, like the persistent-storage grant it is about, and kept until
/// a grant forgets it or the user clears the site's data. Browser-only, so
/// it is not exported from `web.dart`; the composition root builds it.
///
/// A value this can't parse reads as no refusal, so the next page load asks.
/// Reads and writes throw where the browser blocks `localStorage`;
/// [PersistentStorageRequest] treats that as no record.
final class LocalStoragePersistRefusals implements PersistRefusals {
  /// Over `storage`, the window's `localStorage` unless a test passes
  /// another.
  LocalStoragePersistRefusals({this._storage});

  /// The `localStorage` key the refusal's time is stored under.
  static const String key = 'bge.storage.persist_refused_at';

  final web.Storage? _storage;

  web.Storage get _local => _storage ?? web.window.localStorage;

  @override
  DateTime? read() {
    final stored = _local.getItem(key);
    return stored == null ? null : DateTime.tryParse(stored);
  }

  @override
  void write(DateTime? refusedAt) {
    if (refusedAt == null) {
      _local.removeItem(key);
    } else {
      _local.setItem(key, refusedAt.toUtc().toIso8601String());
    }
  }
}
