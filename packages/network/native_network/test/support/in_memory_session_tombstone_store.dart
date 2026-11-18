import 'package:interfaces/repositories.dart';

/// A [SessionTombstoneStore] held in memory.
///
/// Sharing one instance between two `TokenStorageService`s is what stands in
/// for a restart: the marker outlives the service, as the meta database does.
class InMemorySessionTombstoneStore implements SessionTombstoneStore {
  /// The `bgeServerId`s currently marked.
  final Set<String> revoked = {};

  /// Makes both [markRevoked] and [clearRevoked] throw.
  bool failWrites = false;

  /// Makes [isRevoked] throw.
  bool failReads = false;

  /// How many times [isRevoked] was called.
  int reads = 0;

  /// When set, [isRevoked] waits for this after it has read its answer, like a
  /// query whose result is on its way back. A change to [revoked] in the
  /// meantime does not alter what that read reports.
  Future<void>? holdReads;

  /// When set, [markRevoked] and [clearRevoked] wait for this before they
  /// change anything.
  Future<void>? holdWrites;

  @override
  Future<bool> isRevoked(String bgeServerId) async {
    reads += 1;
    if (failReads) throw StateError('meta database read failed');
    final answer = revoked.contains(bgeServerId);
    await holdReads;
    return answer;
  }

  @override
  Future<void> markRevoked(String bgeServerId) async {
    if (failWrites) throw StateError('meta database write failed');
    await holdWrites;
    revoked.add(bgeServerId);
  }

  @override
  Future<void> clearRevoked(String bgeServerId) async {
    if (failWrites) throw StateError('meta database write failed');
    await holdWrites;
    revoked.remove(bgeServerId);
  }
}
