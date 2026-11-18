## Unreleased

* Native token custody moved to the new `native_network` package (#62):
  `AuthRepositoryImpl`, `TokenStorageService`, `TokenInterceptor`,
  `registerServerNetwork` and `NetworkScopeInstaller` are no longer exported
  from here, and `flutter_secure_storage` and `crypto` are no longer
  dependencies. `redactUri` is now exported.
* Export the auth wire-error and request helpers both auth repositories
  share (#877): `mapAuthDioException`, `assertAuthSuccess`, `decodeAuthBody`,
  `isAuthSuccessStatus`, `isEmailAlreadyExists`, `forbiddenRefusal`,
  `authRejectionCode`, `requireEmailPasswordStrategy`, `postSignIn` and
  `postSignUp`.

## 0.0.1

* Add `HouseholdRemoteDataSourceImpl` (#39): `POST /api/households` over the
  shared per-server Dio, unwrapping the `{ message, household }` envelope,
  with transient/permanent failure classification
  (`HouseholdRemoteTransientException` / `HouseholdRemotePermanentException`)
  and registration in `registerServerNetwork` alongside the feedback
  transport.
