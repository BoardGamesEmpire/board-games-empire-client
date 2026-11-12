# server_settings

The admin "Server settings" section (#807). The server keeps one settings
row. An admin reads it and saves it one group at a time: Mail (host, port,
connection security, user, password, From) and Sign-in (password resets and
how a sign-in provider is linked to an existing account).

## Nothing is cached

The screen reads the row whenever it opens, and every save goes straight to
the server. There is no drift table or web store.

## Who may save

The save is offered while the session's `CallerAccessRepository` allows
update on `ResourceType.systemSetting` (#456). While the answer is unknown,
and with no repository to ask, nothing can be saved and a save is dropped. A
403 asks again, and the controls follow what the next answer says.

## Shape

- `ServerSettingsBloc`: reads the row, then saves one `SettingsGroup` at a
  time. A save sends only the patch it is given, one at a time, and an empty
  patch sends nothing. Each group keeps its own failure and its own "saved"
  mark, and `revision` moves on every read and every save that landed so a form
  knows when to take the server's values again.
- `serverSettingsResourceTypes`: the resource types the screen gates its
  controls on, which both compositions hand to `CallerAccessInstaller`.

The remote is `SystemSettingsRemoteDataSource` in `network_interface`.
