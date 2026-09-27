## 0.0.1

* Initial release (#259, with the hydrate half of #44): `GameCollectionHydrator`
  drains the user's collection into the cache, writing each row's platform
  game summary before its entry, then runs one `updatedSince` catch-up pass
  after a multi-page drain. `GameCollectionHydrateInstaller` starts it on
  user-session activation on native and web, and registers it with the
  session rehydrator.
