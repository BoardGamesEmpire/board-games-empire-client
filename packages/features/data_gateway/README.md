# data_gateway

The DataGateway admin screens (#41). A DataGateway is the server's connection
to an outside source of game data, such as a BoardGameGeek bridge. An admin
lists them, adds, edits and deletes them, and connects or disconnects each one.

## Nothing is cached

The screens read from the server whenever they open, and every change goes
straight to the server. There is no drift table or web store. It is
installation configuration, and every action on the screen needs the server
anyway.

## Who sees what

Owner and Admin may read and change DataGateways. Moderator may read them and
not change them. Other roles may do neither. No route tells the client which
of these the user is, so `DataGatewayAccess` learns it from the API's own
refusals:

- `DataGatewayAccessInstaller` runs on every sign-in and reads one row,
  unawaited. A 200 shows the Admin entry in the home drawer; a 403 hides it,
  once a second read two seconds later is refused too. The server writes a
  new user's roles after sign-up has answered, so a read sent straight after
  it is refused even for the first owner (backend#490).
  A read that fails for another reason leaves the answer unknown, and the
  session's rehydrator asks again on the next connectivity edge or resume.
- A deep link to the screen reaches it either way. A refused read shows an
  access-denied state.
- Change actions show to everyone who can read. The first 403 on a change
  hides them, here and on the form, until the session ends.

#456 replaces the last rule with the caller's abilities once backend#757
exposes them.

## What a row says

Name, the address and port the server dials, and enabled or disabled. Not
"connected": the server stores only `enabled`. Connecting sets `enabled`
first, so a connect that failed leaves the DataGateway enabled, and the server
auto-disables one after repeated failures. A connect or disconnect reports its
answer once, in a banner above the list.

## Credentials

The forms create and edit DataGateways with the "None" auth type only, and
have no credentials field: the server's other auth types do not connect yet.
The `DataGateway` model has no field for `authParameters` either, so the
stored credentials the server returns until backend#753 are never parsed.

## Shape

- `DataGatewayListScreen` with `DataGatewayListBloc`: the list, its row
  actions, and the outcome banner.
- `DataGatewayFormScreen` with `DataGatewayFormBloc` and `DataGatewayForm`:
  one form for add and edit. An edit reads its row afresh, sends only the
  fields that changed, and is not sent at all when nothing did.
- `DataGatewayAccess` and `DataGatewayAccessInstaller`: the session's access,
  above.

The remote is `DataGatewayRemoteDataSource` in `network_interface`,
implemented in `dio_network` and registered per server on both platforms.

## Wiring (owned by `app_shell` and the platform compositions)

- **Routes**: `/admin/data-gateways`, with `new` and `:dataGatewayId/edit`
  beneath it.
- **Drawer**: the Admin entry, shown while `DataGatewayAccess` says the read
  was granted.
- **Scope**: `DataGatewayAccessInstaller` in both user-scope installer lists,
  after `SessionRehydratorInstaller`.
- **Localizations**: `DataGatewayLocalizations.delegate`, registered by
  `BgeApp`.
