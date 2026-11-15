# server_settings

The admin "Server settings" section (#807). The server keeps one settings
row. An admin reads it and saves it one group at a time: Mail (host, port,
connection security, user, password and From) and Registration and sign-in
(#894: whether people may create an account, change their username and
reset a forgotten password, the reset link lifetime, and how a sign-in
provider is linked to an existing account).

## Nothing is cached

The screen reads the row whenever it opens, and every save goes straight to
the server. There is no drift table or web store.

## Who may save

The save is offered while the session's `CallerAccessRepository` allows
update on `ResourceType.systemSetting` (#456). While the answer is unknown,
and with no repository to ask, nothing can be saved and a save is dropped. A
403 asks again, and the controls follow what the next answer says.

## Shape

- `ServerSettingsScreen`: the page (#807). It owns both blocs and shows the
  Mail group, with its test email, and the Registration and sign-in group
  under their headings. When the role may read the settings but not change
  them, a banner at the top says so, and there is no Save and no test email.
- `MailSettingsForm` and `RegistrationSettingsForm`: one form per group,
  each with its own Save. A form takes the server's values again only after
  its own save, or when it holds nothing unsaved, so one group's save never
  discards the other's edits. `RegistrationSettingsForm` is built on
  `SettingsGroupForm`, which keeps those rules for any group of plain
  controls; Mail, with its saved password and test email, keeps its own.
- `MailTestBloc`: sends a test email through the saved settings, then reads
  the unread notifications every 5 seconds, for up to 2 minutes, for its
  result. The screen stops it as its route leaves, popped or dropped by the
  router. An edit to the Mail group retires the outcome, even one that lands
  after the edit.
- `ServerSettingsBloc`: reads the row, then saves one `SettingsGroup` at a
  time. A save sends only the patch it is given, one at a time, and an empty
  patch sends nothing. Each group keeps its own failure and its own "saved"
  mark, and `revision` moves on every read and every save that landed so a form
  knows when to take the server's values again.
- `serverSettingsResourceTypes`: the resource types the screen gates its
  controls on, which both compositions hand to `CallerAccessInstaller`.

The remotes are `SystemSettingsRemoteDataSource` and
`NotificationRemoteDataSource` in `network_interface`.
