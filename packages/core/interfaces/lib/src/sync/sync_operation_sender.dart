import 'package:models/domain.dart';

/// Delivers one queued op to the server and records what became of it
/// (#121).
///
/// The one path every sender takes: claim the entry, send the op, then
/// acknowledge it, park it, count the failure or hand it back. A write's
/// immediate send ([SendQueuedOpNow.sendNow]) and the queue drain both come
/// through here, so each outcome's rule applies to both the same way.
///
/// ## How a failed request is judged
///
/// - **Refused as it stands**: a permanent or not-found answer that isn't a
///   success. The entry is parked ([SyncQueueRepository.park]), not
///   cancelled: kept with its error and its rows still dirty, and sent by no
///   pass until someone retries or discards it by hand (#190). See
///   [SyncParked].
/// - **Processed and failed**, or the client faulted: counted with
///   [SyncQueueRepository.markFailed]. See [SyncFailure] for which answers
///   those are.
/// - **Never processed**, or refused for the session: handed back uncounted
///   with [SyncQueueRepository.release].
///
/// A removal the server reports as already done is a delivery: the entry's
/// tombstone is purged and the op completed together
/// ([GameCollectionRepository.confirmRemoved]).
abstract interface class SyncOperationSender {
  /// Claims [entryId], sends [operation], and records the outcome on the
  /// queue entry.
  ///
  /// [operation] is the op queued under [entryId]. A household or event
  /// create goes out keyed by its `localId`, so a retry after a lost
  /// response returns what the first attempt made (#131, #499).
  ///
  /// An op for a collection entry is sent as the queue holds it now, which
  /// an earlier add's acknowledgement may have moved to the server's id
  /// (#429), and only where the drain would send it (#45). An earlier op
  /// for the same entry holds it back unless that op is exhausted, and an
  /// exhausted add still holds back an update or a removal while the entry
  /// is local-only. A held op is not claimed and comes back
  /// [SyncNotClaimed]: it stays queued, and the drain sends the entry's ops
  /// in order. This is the path for a write's immediate send; the drain
  /// sends through [deliverEntry] and keeps the order itself.
  ///
  /// Never throws for anything the send or its acknowledgement does: those
  /// all come back as a [SyncDelivery]. A queue write that records the
  /// outcome is bookkeeping, so its failure is logged and leaves the entry
  /// claimed until its lease runs out. Throws only when reading or claiming
  /// the entry fails, in which case nothing was sent; a queue disposed with
  /// its session throws [StateError] there.
  Future<SyncDelivery> deliver(String entryId, SyncOperation operation);

  /// Delivers the op [entry] holds, as [deliver] does.
  ///
  /// For a sender working from its own read of the queue. The entry is
  /// claimed only while it still holds the payload [entry] was read with
  /// ([SyncQueueRepository.claim]): an op rewritten since, as an add's
  /// acknowledgement rewrites the ops queued behind it (#429), comes back
  /// [SyncNotClaimed], for a sender that reads it again to send.
  ///
  /// A payload that won't decode is never sent: the entry is claimed and the
  /// attempt counted as a client fault ([SyncFailure.invalidOp]), so an
  /// entry no build can read is bounded rather than retried forever, and
  /// never parked, since no server judged it.
  Future<SyncDelivery> deliverEntry(SyncQueueEntry entry);
}

/// The send a write makes of the op it just queued (#45).
///
/// ## The rule
///
/// A change the app shows before the server confirms it is written locally
/// and queued in one transaction, then sent at once through [sendNow]. The
/// repository that queues it hands back the queue entry's id and the op,
/// and the caller sends them. A write is never queued and left for a drain
/// to find: nothing wakes the drain on an enqueue, so the change would wait
/// for the next connectivity edge or resume, and on web, which has no drain
/// yet (#447), for ever.
///
/// No connectivity check comes first. The send's answer is the real one: a
/// send that can't reach the server leaves the op queued, and the drain
/// retries it. So "send now if online, else queue" needs nothing more, and
/// nothing changes here when web gains a drain.
///
/// A change whose outcome is the server's to decide, or that reaches other
/// people, goes to the server directly instead and is never queued: an
/// invite, a member's approval, an RSVP, an admin setting.
///
/// The household create, the event create and the collection add send this
/// way.
extension SendQueuedOpNow on SyncOperationSender {
  /// Sends the op a write just queued under [entryId], as
  /// [SyncOperationSender.deliver] does.
  ///
  /// A claim that throws sent nothing and leaves the op queued for the
  /// drain, so it is handed to [onClaimFailed] to log and comes back as
  /// [SyncNotClaimed]. Never throws.
  Future<SyncDelivery> sendNow(
    String entryId,
    SyncOperation operation, {
    required void Function(Object error, StackTrace stackTrace) onClaimFailed,
  }) async {
    try {
      return await deliver(entryId, operation);
    } on Object catch (error, stackTrace) {
      onClaimFailed(error, stackTrace);
      return const SyncNotClaimed();
    }
  }
}

/// What [SyncOperationSender.deliver] did with one queued op.
sealed class SyncDelivery {
  const SyncDelivery();
}

/// The server applied the op and the cache now holds its answer. The entry
/// is completed.
final class SyncDelivered extends SyncDelivery {
  const SyncDelivered({this.householdId, this.eventId});

  /// For a household create, the id the server assigned, which the
  /// optimistic row now carries. Null for every other op.
  final String? householdId;

  /// For an event create, the id the server assigned, which the cache now
  /// holds the event under (#499). Null for a replay of a create whose event
  /// was deleted since, which leaves no event, and for every other op.
  final String? eventId;
}

/// Another sender holds the entry, or it can no longer be taken: completed,
/// exhausted or gone, or, for [SyncOperationSender.deliverEntry], rewritten
/// since it was read. From [SendQueuedOpNow.sendNow], also a claim that
/// threw. Nothing was sent.
final class SyncNotClaimed extends SyncDelivery {
  const SyncNotClaimed();
}

/// The server refused the op as it stands, so it is parked: exhausted but
/// kept, with [error] recorded, and the rows it would have confirmed still
/// dirty.
final class SyncParked extends SyncDelivery {
  const SyncParked(this.error);

  /// What the server answered.
  final Object error;
}

/// The attempt failed and the op stays queued.
final class SyncFailed extends SyncDelivery {
  const SyncFailed(this.failure, this.error);

  /// Which kind of failure it was, and so whether it was counted and
  /// whether a drain should stop.
  final SyncFailure failure;

  /// What was thrown.
  final Object error;
}

/// Why an attempt failed, which decides whether it counts against the op's
/// retries and whether a drain goes on to the next op (#121).
///
/// The rule underneath: an attempt counts when the application processed it
/// or the client faulted, and is handed back uncounted when it never reached
/// the application. A failure that is about the op itself lets the drain go
/// on; any other stops it, so a server that is down or throttling costs one
/// request per pass rather than one per queued op.
enum SyncFailure {
  /// No answer, or an answer from something in front of the application:
  /// no response, 408, 429, a 1xx or 3xx, and the 403, 404 and 407 the
  /// remotes classify as never having reached it. Handed back uncounted.
  unreachable(counted: false, stopsPass: true),

  /// A 401: the session was refused. Handed back uncounted, and worth asking
  /// the auth layer whether the session still stands.
  sessionRejected(counted: false, stopsPass: true),

  /// The application processed the request and failed: a 5xx, a 409 that
  /// says it is retryable (#431), or any other answer it wrote that is
  /// neither a refusal nor a success. Counted.
  serverError(counted: true, stopsPass: true),

  /// The op itself can't be sent: a request the server would refuse, a
  /// payload that won't map, or a malformed id. Counted, so a fault that
  /// recurs on every attempt is bounded rather than retried forever. Never
  /// parked, since the server never judged it (#131).
  invalidOp(counted: true, stopsPass: false),

  /// The server applied the op but recording that here failed, the server
  /// answered with a success this device couldn't read, or something
  /// unexpected threw. Counted; the retry is replayed rather than applied
  /// twice, since every op type is safe to deliver again.
  localFault(counted: true, stopsPass: true);

  const SyncFailure({required this.counted, required this.stopsPass});

  /// Whether the attempt counts against the op's retries.
  final bool counted;

  /// Whether a drain stops its pass here rather than going on to the next
  /// op.
  final bool stopsPass;
}
