# sync_queue

The sync queue's delivery: one sender for every queued op, and the drain that
runs it (#121).

The directory is `features/sync`, but the package is `sync_queue`: `sync` is a
Dart contextual keyword.

## The sender

`SyncOperationSenderImpl` is the one path a queued op takes to the server. The
create-household screen's inline send and the drain both call it, so the rules
below apply to both the same way. It claims the entry, sends the op through the
remote that owns it, and records what happened:

- **Delivered**: the server's answer is reconciled through the repository that
  owns the row, and the entry is completed in the same transaction. A household
  create goes out keyed by its `localId`, so a retry after a lost response
  returns the first household (#131). A removal the server reports as already
  done is settled locally, tombstone and entry together.
- **Refused as it stands** (a permanent or not-found answer that isn't a
  success): the entry is **parked**. It is kept with its error, its rows stay
  dirty, and nothing sends it again until someone retries or discards it by
  hand (#190).
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

## Composition

- `SyncSenderInstaller` registers the sender. Both platforms run it, after
  `UserSessionScopeInstaller`.
- `SyncQueueDrainInstaller` starts the drain. Native only for now; the web
  drain needs a Web Lock and a check of whose session is sending, which is
  #447.

The class docs carry the rest.
