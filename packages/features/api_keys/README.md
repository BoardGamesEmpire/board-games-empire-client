# api_keys

Your API keys on a server (#1028): the keys a script or another app uses to
act as you, each holding only the permissions you gave it.

## Shape

- `ApiKeyListScreen`: the list. It reads the first page of keys and the
  permissions you may grant together when it opens, and again when a key's
  own page closes. An All / Enabled / Disabled filter works over the pages
  loaded so far; the server orders the keys newest first. It owns its bloc.
- `ApiKeyListBloc`: the paged read, the filter, and the grantable
  permissions by slug. A failed grantable read never fails the list: the rows
  then give a count of permissions without a risk level.
- `scopeSummary`: a key's permissions in words, "3 permissions, highest risk
  High", for its row.
- `apiKeyFailureOf` and `apiKeyFailureMessage`: every `ApiKeyRemoteException`
  as an `ApiKeyFailure`, and the words for it. A refusal this client has no
  words of its own for shows the server's message.

Online only: nothing is stored on the device, and the secret of a new key is
never stored, logged or put in a message. The remote comes in as a
parameter, so this package never imports `package:di`.
