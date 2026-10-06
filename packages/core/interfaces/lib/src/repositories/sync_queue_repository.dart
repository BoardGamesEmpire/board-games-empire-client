import 'package:models/domain.dart';

/// Manages the local sync queue for offline operations.
///
/// The sync engine reads from this repository, sends operations to the server,
/// and marks entries completed or failed. All writes go through here — no
/// component should write directly to the server without enqueuing first.
///
/// ## Per-user scoping (#147)
///
/// Implementations are constructed **per user session** and every method —
/// enqueue, reads, status transitions, maintenance, and
/// [remapCollectionId] — operates only on entries the session's user
/// enqueued. Entries belonging to other users of the same server are
/// invisible and untouchable through this interface: on a shared device a
/// departed user's queued offline writes lie dormant (intact, per the D8
/// retention rule from #98/#142) until that user signs back in, and a
/// drain worker (#121) operating through this interface can never push
/// one user's writes under another user's session. The scoping lives in
/// the data model (a stamped, filtered user id), not in consumer
/// discipline; the method signatures are deliberately unchanged.
abstract class SyncQueueRepository {
  /// Enqueues a new operation. Returns the created entry.
  Future<SyncQueueEntry> enqueue(SyncOperation operation);

  /// Returns every entry [claim] would take now, in [createdAt] order with
  /// rowid as a stable tiebreaker.
  ///
  /// That is every entry under [SyncQueueEntry.maxRetries] that is
  /// [SyncStatus.pending] or [SyncStatus.failed], or [SyncStatus.inProgress]
  /// with a claim older than [SyncQueueEntry.claimLease] (#430). The listing
  /// and [claim] share one predicate, so a sender can't list an entry it
  /// can't claim, or miss one it could. Listing an entry doesn't take it:
  /// a sender claims each one before sending it.
  Future<List<SyncQueueEntry>> getPendingEntries();

  /// Returns all of the current user's entries regardless of status.
  /// Useful for diagnostics. Other users' entries are never included
  /// (#147).
  Future<List<SyncQueueEntry>> getAllEntries();

  /// Takes [id] for sending: marks it [SyncStatus.inProgress], stamps the
  /// attempt time, and returns whether this caller won it (#430).
  ///
  /// One conditional write, so of several senders racing for one entry —
  /// a drain and the inline household send, or two web tabs over one
  /// database — exactly one gets `true`. It succeeds only for an entry
  /// [getPendingEntries] would list: under [SyncQueueEntry.maxRetries],
  /// and pending, failed, or claimed longer than
  /// [SyncQueueEntry.claimLease] ago. An expired claim is how a sender
  /// that died mid-send gives the entry back.
  ///
  /// Returns `false` for an entry someone else holds, one that is
  /// completed or exhausted, and an id that doesn't exist or belongs to
  /// another user. Every sender must claim before sending.
  ///
  /// The lease is judged by the device's own clock, not the
  /// server-corrected one: the senders sharing the queue share the device,
  /// and a skew correction must not shorten or stretch a claim.
  Future<bool> claim(String id);

  /// Hands a claimed [id] back as [SyncStatus.pending] without counting a
  /// retry (#430).
  ///
  /// For an attempt that didn't really happen: a client-side fault before
  /// any request, a send the server accepted but whose local acknowledgement
  /// failed, or a drain stopping on a lost session. A real failed attempt
  /// is [markFailed]. Only an [SyncStatus.inProgress] entry moves, so a late
  /// release can't reopen a completed entry or clear a failure. A silent
  /// no-op otherwise.
  ///
  /// Like [markFailed], it doesn't check whose claim it is: a sender whose
  /// lease expired and was retaken can hand back the other sender's claim.
  /// That sender's send then overlaps a new one, which the lease already
  /// accepts (#430).
  Future<void> release(String id);

  /// Marks [id] as [SyncStatus.completed].
  ///
  /// Today this only flips the `status` column — there is no separate
  /// `completedAt` timestamp or other completion metadata, despite
  /// historic notes that suggested otherwise. Implementations should
  /// be idempotent: calling on an id that's already completed (or no
  /// longer present) is a silent no-op.
  Future<void> markCompleted(String id);

  /// Marks [id] as [SyncStatus.failed], increments retry count, stores [error].
  ///
  /// A completed entry is left alone (#430): a sender whose lease expired
  /// can still be waiting on its request after another sender delivered
  /// the op, and its failure must not queue the op again, where a re-sent
  /// add or update would overwrite what the user changed since. Otherwise
  /// it doesn't check whose claim it is, so such a sender can still count
  /// a failure against an op someone else now holds.
  Future<void> markFailed(String id, {required String error});

  /// Removes all completed entries. Called periodically to keep the queue lean.
  Future<int> purgeCompleted();

  /// Rewrites the payload of every entry not yet completed whose target
  /// collection id matches [oldCollectionId], replacing it with
  /// [newCollectionId].
  ///
  /// Used by [GameCollectionRepository.reconcileFromServer] when the
  /// server returns a canonical id different from the one the local
  /// row was created with: pending [UpdateCollectionOperation] /
  /// [RemoveFromCollectionOperation] entries queued against the
  /// local-only id would otherwise be sent to the server with an id
  /// the server doesn't know.
  ///
  /// Affects:
  ///
  /// - [AddToCollectionOperation.localId] (informational on the op,
  ///   kept consistent so the serialized form doesn't lie about
  ///   which local row it created).
  /// - [UpdateCollectionOperation.collectionId] (the actual target).
  /// - [RemoveFromCollectionOperation.collectionId] (the actual
  ///   target).
  ///
  /// Status filter: every entry not yet completed is touched — pending,
  /// failed, claimed and exhausted alike, the set
  /// [getOutstandingOpsFor] returns (#429). Each of them can still be
  /// sent: a claimed entry whose send fails is retried, and an exhausted
  /// one may be retried by hand. A retry must carry the id the server
  /// knows, and the entry's later acknowledgements must find the op under
  /// it; an op left on the old id would drop out of both. Rewriting a
  /// claimed entry doesn't change a request already on the wire, only
  /// what a retry sends. A `completed` entry is done and left alone.
  ///
  /// Returns the number of entries actually rewritten. A return
  /// value of 0 is normal and means no pending op referenced
  /// [oldCollectionId].
  Future<int> remapCollectionId({
    required String oldCollectionId,
    required String newCollectionId,
  });

  /// Returns every queue entry not yet completed whose operation targets
  /// the collection entry [collectionId], in queue order (#429).
  ///
  /// "Not completed" is deliberate: pending, failed, claimed **and
  /// exhausted** entries are all returned. An exhausted entry is a change
  /// that never landed, and a claimed one may not land either, so
  /// [GameCollectionRepository.reconcileFromServer] uses this to keep a
  /// collection entry dirty, and to replay its later changes, while any
  /// remain.
  ///
  /// The target is [AddToCollectionOperation.localId],
  /// [UpdateCollectionOperation.collectionId] or
  /// [RemoveFromCollectionOperation.collectionId]. After a reassignment
  /// [remapCollectionId] has moved every one of them to the new id, so one
  /// id finds them all. Entries whose payload cannot be parsed are
  /// skipped.
  ///
  /// [including] names one more entry to return in its place, whatever its
  /// status, as long as it targets [collectionId]. An acknowledgement
  /// passes the op it acknowledges, so it can tell which outstanding ops
  /// were queued after it, even when an earlier delivery of the same op
  /// already completed it.
  Future<List<SyncQueueEntry>> getOutstandingOpsFor(
    String collectionId, {
    String? including,
  });

  /// Total count of outstanding sync work. Matches the same set
  /// [getPendingEntries] returns plus entries whose claim is live, i.e.
  /// entries under `SyncQueueEntry.maxRetries` in:
  ///
  /// - [SyncStatus.pending]
  /// - [SyncStatus.inProgress], live or expired (being sent, or waiting
  ///   for its lease to run out — not done either way)
  /// - [SyncStatus.failed] (retryable failures — the worker will pick
  ///   them up on its next cycle)
  ///
  /// Used for UI badge display. Implementations MUST keep this in
  /// lockstep with [getPendingEntries] / [watchPendingCount]: a
  /// change to the predicate in one requires a matching change in
  /// the others, otherwise the badge and the worker's pickup queue
  /// diverge.
  Future<int> getPendingCount();

  /// Stream emitting the pending count on any queue change. Same
  /// status-set semantics as [getPendingCount].
  Stream<int> watchPendingCount();
}
