## Unreleased

* New package (#62): native token custody moved here from `dio_network` —
  `AuthRepositoryImpl`, `TokenStorageService`, `TokenInterceptor`,
  `registerServerNetwork` and `NetworkScopeInstaller`, with the provider
  sign-in helpers (`pkce`, `server_address` and friends) and their tests.
  `flutter_secure_storage` and `crypto` now depend from here, so the browser
  build no longer pulls them in.
* `AuthRepositoryImpl` now maps auth errors, decodes auth bodies and sends
  the email/password sign-in and sign-up requests through the helpers it
  shares with the web repository in `dio_network` (#877). Its grant handling
  stays its own. No behaviour change.
* Provider sign-in moved out of `AuthRepositoryImpl` into `ProviderSignInFlow`
  (`auth/provider_sign_in/`), which owns the pending attempt (#879). The
  repository's grant-body check now uses the shared `isAuthSuccessStatus`.
