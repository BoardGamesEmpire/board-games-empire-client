## 0.0.1

* Initial release (#1028): `ApiKeyListScreen` lists your API keys on a
  server, filtered by status, with each key's permissions in words.
* `ApiKeyDetailScreen` reads one key, with every permission it holds and
  its risk in words, enables or disables it, and deletes it after asking.
* `ApiKeyCreateScreen` makes a key: a name, its permissions or "Everything I
  can do", and how long it lasts. It asks before a key is given a Critical
  permission, shows the new key's secret once, in place, and asks before
  Back leaves it. The list offers it through "Create key".
* `ApiKeyCreateLeaveGuard` lets the route's holder ask the create page
  before it takes the route away without a pop, so the browser's Back and a
  move elsewhere ask too.
