# data_gateway

The DataGateway admin screens (#41, #457). A DataGateway is the server's
connection to an outside source of game data, such as a BoardGameGeek bridge.
An admin lists them, adds, edits and deletes them, and connects or disconnects
each one. Each also has a page of its own that shows whether the server uses
it yet, how its interviews and lists went, which capabilities are on, and which
of the language names it uses are still to be linked.

## Nothing is cached

The screens read from the server whenever they open, and the list and the
detail page read again whenever they come back into view. Every change goes
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
- A deep link to a screen reaches it either way. A refused read shows an
  access-denied state.
- Change actions show to everyone who can read. The first 403 on a change
  hides them on the list, the form and the detail page until the session ends.
  On the detail page the capability switches stay in place and stop taking
  presses, and the worklist's row menus go.

#456 replaces the last rule with the caller's abilities once backend#757
exposes them.

## What a row says

Name, the address and port the server dials, and enabled or disabled. Not
"connected": the server stores only `enabled`. Connecting sets `enabled`
first, so a connect that failed leaves the DataGateway enabled, and the server
auto-disables one after repeated failures. A connect or disconnect reports its
answer once, in a banner above the list.

An enabled row also says whether the server uses the DataGateway yet (#457).
The server doesn't use one until an interview has succeeded, which is why an
enabled DataGateway can return nothing. The line is an icon and words, never
color alone:

- **Not in use yet: waiting for its first interview.** The server has no
  interview on record, success or failure. That includes a DataGateway the
  server couldn't connect to at all: a connect that fails before an interview
  can start is recorded nowhere, so the line stays even right after Interview
  again reports that the interview failed. Recording it is the backend's to
  fix.
- **Not in use,** with a reason. No interview has succeeded, and the last one
  failed.
- **Last interview failed,** with a reason. An earlier one succeeded, and the
  server keeps using what it found.
- **In use.** An interview succeeded, and none has failed since.

A reason is one of the server's three failure codes in words: it didn't
answer, it can't describe itself so it may need updating, or it couldn't
describe itself. A code this client doesn't know reads "something went wrong"
rather than failing the row. The line is read from the row's `interview` block
as the server sends it. The server has already decided which failure is
current, so the client compares no timestamps. A disabled row has no line,
only its badge: the server doesn't use it whatever its interviews say.

## The detail page

A tap on a list row opens `/admin/data-gateways/:dataGatewayId` (#457). It
shows, top to bottom:

- **The name,** whole, as the page's first heading. The app bar cuts a long
  one short: at 200% text on a phone, to a few letters.
- **Status.** Enabled or disabled, and for an enabled one the row's line.
- **Interview.** When it was first and last interviewed, the failure that is
  current, and Interview again, on an enabled DataGateway while changes are
  allowed.
- **Lists.** One row for each list the DataGateway declares: languages,
  platforms, categories and mechanics. Each says when it last loaded and,
  while one is current, when and why it failed. A list with nothing recorded
  yet reads "Not loaded yet", not as a failure. One an admin switched off
  keeps its row and reads "Switched off" alone, so switching it doesn't move
  the switches below. The
  lists load as jobs after an interview (backend#718), so a re-interview's
  answer doesn't carry them, and they show a few minutes later.
- **Capabilities.** A switch for each thing the DataGateway says it can do,
  and for each one an admin switched off.
- **Language names to review.** The worklist, below.

Dates are in the device's time, with the year when it isn't this year, so a
last interview from last year can't pass for a recent one.

What an action answered shows in the page's footer: what an action on the
DataGateway answered, then what an action on a language link answered, each
with its own Dismiss. The footer is always built and always on screen, so a
banner there is seen and announced wherever the admin is working on the long
page, and its coming and going moves no control. When a refusal, or a row
found disabled, takes away the control that had focus, focus goes to the
banner's Dismiss, or with no banner to the first switch still taking presses,
or else to refresh.

**Interview again** waits 60 seconds for the answer. In a browser that is the
connect timeout as well, because a browser reports a slow answer as a connect
timeout. Elsewhere connecting keeps the default 10 seconds, so a server that
can't be reached says so at once, and it counts as no answer. The server sets
no deadline of its own (backend#722), and the interview carries on after the
client stops waiting, so the default 10 seconds would call a slow success a
failure. An interview with no answer, from a timeout, a proxy's 504 or a
dropped connection, isn't a failure either: the page says so, reads the row
again, and sends nothing more until that read has answered.

**Capability switches** send the whole `disabledCapabilities` list every time,
because the server takes the whole list and `[]` switches everything back on.
The list is built from the last row the server sent, so two quick switches
can't undo each other, and the page does one write at a time. A switch pressed
during a write goes when that write has answered, and Interview again pressed
then goes after it, so neither is lost. Names stay the
server's own strings, never an enum: a capability this client can't label
still gets a switch, as "Other: name", and stays in the list it sends. A write
that gets no usable answer says so and doesn't claim the change didn't happen
(#627), since it may have applied, and the page reads the row again before it
sends another.

### The language worklist

A DataGateway names languages its own way, such as "Czech", and each name it
uses is a language link. The worklist shows the links waiting on a review,
pending and unresolved, and can show the ignored and the resolved ones too:
link works on a link in any status, so linking an ignored link is how an
ignore is undone. A row's menu offers Link to a language and Ignore (an
ignored link offers only Link), and for a pending link Add this language,
which makes the server add the language where it has none and link it. An add
the server won't make, because the link was settled first or names no
registered language, reads the list again. A row says how the value is spelled,
because a value can be listed once per format, such as `en` as a tag and as an
ISO code, and what the DataGateway supplied beside it.

The client reads 50 links a page, and the server orders them by value and has
no other order. Show more counts how far down the server's list it has read,
not the rows on screen, so a link added ahead of them, as a list job does a few
minutes after an interview, doesn't stall it. Asked for by rows shown, the
next page would be one it had read already, and would add nothing every time
after. An action whose answer was lost keeps its row, but the server may have
made the change, so when that would take the link out of the filter the count
goes down one all the same. A page that starts a place early only reads a
link again, which Show more drops; one that starts a place late would skip
the link that moved up. For the same reason a page and an action never overlap:
Show more pressed during an action waits for it, and an action started while a
page is out has that page dropped and read afterwards.

What an action on a link answered shows in the page's footer, under what
an action on the DataGateway answered, so it is on screen wherever the row is
down the list. A sliver page with a footer keeps one viewport of content built
past each edge of its view (`BgePage.footer`), so a row the footer pushes out
of view is still built and keeps its keyboard focus. After an action, focus
returns to the menu of the row worked on, or the row now in its place if that
one left the list, unless the admin has moved focus elsewhere meanwhile. That
holds after a click too: the picker gives focus back to whatever had it last
as it closes, such as the app bar's Back, and that isn't the admin's choice.

### The language picker

Link opens a dialog over `GET /api/languages`. It searches the server's
languages by name once the admin stops typing, 50 languages at a time, with
one row for each of their tags: the language's name, and under it the tag. So
a page of 50 languages can make more or fewer than 50 rows. The server matches
a language's name and nothing else, so a tag such as `pt-BR`, or a place such
as Brazil, finds nothing, and the field says so under it: "Search by language
name, such as Portuguese". The list isn't narrowed to the languages the server
supports. The dialog answers the tag chosen, and the worklist links it.

### Left for #653

The platform, category and mechanic worklists, and the settings that turn
their review on, are #653. They wait on backend#1004, the routes that list
those records, so that a link has something to pick from. This client has no
surface for the review settings either. With `reviewGatewayLanguages` off, the
default, the language worklist holds unresolved links: names the server
couldn't match. A link is parked as pending, a language the server could add,
only while the setting is on, and stays pending until it is settled, even
after the setting goes off again.

## Credentials

The forms create and edit DataGateways with the "None" auth type only, and
have no credentials field: the server's other auth types do not connect yet.
Since backend#753 the server no longer sends a DataGateway's stored
credentials, only whether it has any (`hasAuthParameters`). The `DataGateway`
model reads neither, so nothing here could show or log one.

## Shape

- `DataGatewayListScreen` with `DataGatewayListBloc`: the list, its row
  actions, and the outcome banner. A row opens the detail page.
- `DataGatewayFormScreen` with `DataGatewayFormBloc` and `DataGatewayForm`:
  one form for add and edit. An edit reads its row afresh, sends only the
  fields that changed, and is not sent at all when nothing did.
- `DataGatewayDetailScreen` with `DataGatewayDetailBloc`: one DataGateway's
  page (#457). The bloc reads the row, runs Interview again and writes the
  capability switches.
- `LanguageLinkWorklist` with `LanguageLinkListBloc`: the language worklist on
  the detail page, with its status filter, its paging and the link, ignore and
  accept actions. `LanguageLinkOutcomeBanner` is the banner that answers them,
  which the detail page's footer shows under its own.
- `showLanguageTagPicker` with `LanguageTagSearchCubit`: the dialog that Link
  opens.
- `DataGatewayEnabledBadge` and `DataGatewayStatusLine`, in
  `data_gateway_status.dart`: a row's badge and status line, shared by the
  list and the detail page.
- `DataGatewayAccess` and `DataGatewayAccessInstaller`: the session's access,
  above.

The remote is `DataGatewayRemoteDataSource` in `network_interface`,
implemented in `dio_network` and registered per server on both platforms. It
also carries the interview, the capability write, the language links and the
language catalogue the picker searches.

## Wiring (owned by `app_shell` and the platform compositions)

- **Routes**: `/admin/data-gateways`, with `new`, `:dataGatewayId` and
  `:dataGatewayId/edit` beneath it. `new` is declared first: it is a legal id,
  and would otherwise open as the detail page of a DataGateway called "new".
  The forms and the detail page are pushed from the list, so a deep link to
  one builds the list beneath it.
- **Drawer**: the Admin entry, shown while `DataGatewayAccess` says the read
  was granted.
- **Scope**: `DataGatewayAccessInstaller` in both user-scope installer lists,
  after `SessionRehydratorInstaller`.
- **Localizations**: `DataGatewayLocalizations.delegate`, registered by
  `BgeApp`.
