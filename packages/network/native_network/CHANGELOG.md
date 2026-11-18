## Unreleased

* New package (#62): native token custody moved here from `dio_network` —
  `AuthRepositoryImpl`, `TokenStorageService`, `TokenInterceptor`,
  `registerServerNetwork` and `NetworkScopeInstaller`, with the provider
  sign-in helpers (`pkce`, `server_address` and friends) and their tests.
  `flutter_secure_storage` and `crypto` now depend from here, so the browser
  build no longer pulls them in.
