# sync_queue

The sync queue's delivery: one sender for every queued op, the drain that runs
it (#121), and the screen where a stuck op is retried or discarded (#190).

The directory is `features/sync`, but the package is `sync_queue`: `sync` is a
Dart contextual keyword.

## Which writes are queued, and when they are sent

One rule for every write (#45):

- **A change to the user's own data that the app shows before the server
  confirms it** is written locally and queued in one transaction, then sent at
  once with `sendNow` (`SendQueuedOpNow` in `package:interfaces/sync.dart`).
  The repository that queues it returns the queue entry's id and the op; the
  caller sends them. Nothing is queued and left for the drain to find: nothing
  wakes the drain on an enqueue, and web has no drain yet (#447). There is no
  connectivity check first. A send that can't reach the server leaves the op
  queued, and the drain retries it. The household create, the event create and
  the collection add work this way.
- **A change whose outcome is the server's to decide, or that reaches other
  people**, goes to the server directly and is never queued: invites, a
  member's approval, an RSVP or poll vote, admin settings, a game import. It
  fails visibly when the server can't be reached.

An immediate send of an op for a collection entry waits where the drain would
hold it back: behind an earlier op for the same entry that isn't exhausted,
or, for an update or removal, behind an add for an entry the server hasn't
confirmed. It is left queued, and the drain sends the entry's ops in order
(see below). The send reads the op back as the queue holds it, since an
earlier add's acknowledgement may have moved it to the server's id.

## The sender

`SyncOperationSenderImpl` is the one path a queued op takes to the server. A
write's immediate send and the drain both call it, so the rules below apply to
both the same way. It claims the entry, sends the op through the
remote that owns it, and records what happened:

- **Delivered**: the server's answer is reconciled through the repository that
  owns the row, and the entry is completed in the same transaction. A household
  create goes out keyed by its `localId`, so a retry after a lost response
  returns the first household (#131). A removal the server reports as already
  done is settled locally, tombstone and entry together.
- **Refused as it stands** (a permanent or not-found answer that isn't a
  success): the entry is **parked**. It is kept with its error, its rows stay
  dirty, and nothing sends it again until someone retries or discards it by
  hand (see Stuck ops below).
- **Processed and failed** (a 5xx, a retryable 409), answered with a success
  this device couldn't read, or the client faulted: counted against the
  entry's retries.
- **Never processed** (no response, 408, 429, a proxy's answer) or refused
  for the session (401): handed back uncounted.

`SyncFailure` in `interfaces` names each kind of failure and says whether it
counts and whether a drain stops on it.

## The drain

`SyncQueueDrain` sends what the queue holds, in queue order:

- It stops a pass on any failure that isn't about the op itself, so a server
  that is down costs one request per pass. A 401 also asks the auth layer
  whether the session still stands.
- One collection entry's ops go out in order. An update or removal waits behind
  an add that isn't acknowledged yet, since it still names the entry by a local
  id the server has never seen.
- A counted failure waits out a cooldown that grows with the retry count: one
  minute, ten, an hour, then six.

It runs once when a user session activates, and again whenever the session's
`SessionRehydrator` runs a pass (connectivity edge, app resume, entering the
household list) and the drain has something to send. Nothing wakes it on an
enqueue.

A drain's first pass, and then at most one pass an hour, also deletes completed
entries older than a day. They are kept that long so a late acknowledgement of
an op delivered twice still finds its place. Web has no drain until #447, so
nothing deletes them there yet.

## Stuck ops

An op the server refused, or one that ran out of retries, is **stuck**: no pass
sends it, and nothing drops it (#190). `SyncRecovery` is the way out:

- **Retry** puts it back as new, with no cooldown, and sends it through the
  drain on native. On web, until #447, it goes out inline through the sender.
  A collection op goes through `deliver`, which leaves it queued while an
  earlier op for its entry goes first; with no drain, nothing sends it once
  that op is done. A retry the server refuses again says so.
- **Discard** deletes it and undoes what it did on this device, through the
  repository that owns its rows, then refreshes that cache. The repository
  checks that the op is still stuck in the statement that deletes it, so an op
  another tab retried meanwhile is left alone. A discarded add
  for an entry the server never saw deletes the entry, along with the ops
  queued behind it. A discarded household create deletes the household.

`StuckSyncOpsScreen` lists them in plain words, never with the error the queue
recorded, and asks before a discard. `StuckSyncOpsNotice` leads to it from the
home screen while anything is stuck.

## Composition

- `SyncSenderInstaller` registers the sender. Both platforms run it, after
  `UserSessionScopeInstaller`.
- `SyncQueueDrainInstaller` starts the drain. Native only for now; the web
  drain needs a Web Lock and a check of whose session is sending, which is
  #447.

The class docs carry the rest.
