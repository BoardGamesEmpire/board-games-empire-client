# notifications

Your notifications on the active server (#475): one list of every
notification, read or not, each worded from its type and payload and opening
what it's about.

## Shape

- `presentNotification`: a pure function from a `UserNotification` to a
  `NotificationPresentation`, an icon, a title, an optional detail line and
  quote, and a `NotificationTarget`. It never throws. A type this version
  doesn't know, or a payload missing a field the wording needs, is a plain
  row: no target, and the user can only mark it read.
- `NotificationTarget`: a sealed class naming what a row opens in the app's
  own terms. app_shell turns it into a location, so this package names no
  route.

The household notifications are worded today.
