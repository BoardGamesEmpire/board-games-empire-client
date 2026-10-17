# sync_queue

The sync queue's delivery: one sender for every queued op, the drain that runs
it (#121), and the screen where a stuck op is retried or discarded (#190).

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
  drain on native. On web, until #447, a household create goes out inline
  through the sender; a collection op waits for the drain, which is what keeps
  one entry's ops in order. A retry the server refuses again says so.
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
