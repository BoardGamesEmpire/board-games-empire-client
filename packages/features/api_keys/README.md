# api_keys

Your API keys on a server (#1028): the keys a script or another app uses to
act as you, each holding only the permissions you gave it.

## Shape

- `ApiKeyListScreen`: the list. It reads the first page of keys and the
  permissions you may grant together when it opens, and again once a page
  over it has gone, however it went: a pop, the browser's Back, or a page it
  never opened, as when a link builds the list beneath a key's page. That
  page is a key's own, or the one that makes a key, which its "Create key"
  opens. An All / Enabled / Disabled filter works over the pages loaded so
  far; the server orders the keys newest first. It owns its bloc.
- `ApiKeyListBloc`: the paged read, the filter, and the grantable
  permissions by slug. A failed grantable read never fails the list: the rows
  then give a count of permissions without a risk level.
- `ApiKeyDetailScreen`: one key's own page, by id. It reads the key and the
  grantable permissions when it opens, and lists every permission the key
  holds with its risk in words (`ApiKeyScopeList`). A form renames the key,
  changes its permissions (Change permissions swaps the list for a
  `ScopePicker`, the ones it holds ticked) or sets a new expiry
  (`ExpiryControl`), and Save changes sends only what changed: a key that
  holds a permission its owner may no longer give can still be renamed, and
  an unnamed one needn't be named. A
  save that adds a Critical permission the key doesn't hold is asked about
  first. An Enabled switch and Delete, which asks first (`DeleteKeyDialog`),
  write straight to the server. A delete that goes through says so and pops
  the page. It owns its bloc past the route, and says a write the user
  walked away from only while the session it was opened in is live.
- `ApiKeyDetailBloc`: the read, the save, the toggle and the delete, one
  write at a time. A 404 is gone; a failed grantable read never fails the
  page, whose permissions then show their codes, and can't be changed.
- `ApiKeySubmitButton`: the create and edit forms' one filled button. While
  what it sent is on its way it stays enabled and ignores presses, so it
  keeps focus.
- `ApiKeyCreateScreen`: the page that makes a key. A name
  (`apiKeyNameControl`), the permissions it is to hold (`ScopePicker`, with
  "Everything I can do") and how long it lasts (`ExpiryControl`). A key that
  would hold a Critical permission is asked about first
  (`showCriticalConfirm`), and `confirmCritical` is sent only after a yes.
  Once the server makes the key, the page's body becomes a `SecretPanel` on
  the same route: the secret as selectable text, Copy, and Done. Back asks
  before leaving, since the key is not shown again. It owns its bloc, which
  is the only place the secret is held.
- `ApiKeyCreateLeaveGuard`: what the holder of the create page's route asks
  before it takes the route away without a pop, as a router does for the
  browser's Back and for a move to another location. The page answers it:
  yes with nothing to lose, no while a key is on its way, and the Back
  question while the secret shows. It knows nothing of routers.
- `ApiKeyCreateBloc`: the read of the grantable permissions, and the create,
  one at a time. When the server finds a permission Critical that the form
  did not, it reads the permissions again so the page can ask by name.
- `scopeSummary`: a key's permissions in words, "3 permissions, highest risk
  High", for its row.
- `apiKeyFailureOf` and `apiKeyFailureMessage`: every `ApiKeyRemoteException`
  as an `ApiKeyFailure`, and the words for it. A refusal this client has no
  words of its own for shows the server's message.

Online only: nothing is stored on the device, and the secret of a new key is
never stored, logged or put in a message. It is held in
`ApiKeyCreateState.created` alone, whose `toString` leaves it out, and goes
when the create page closes. The remote comes in as a
parameter, so this package never imports `package:di`.
