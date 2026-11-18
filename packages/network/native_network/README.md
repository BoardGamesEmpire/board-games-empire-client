# native_network

The native (mobile and desktop) network stack: bearer-token custody, the
BetterAuth repository and the per-server composition root, over the shared Dio
layer in `dio_network`. Web uses its own stack (`web_network`); nothing here
may be imported from a web build, which is why `flutter_secure_storage` and
`crypto` live in this package and not in `dio_network`.

## Composition root

`registerServerNetwork({container, config, sessionTombstones})` is the one place
that knows how the pieces fit together. It builds the **per-server** stack and
registers it into that server's DI container:

```
TokenStorageService -> TokenInterceptor -> DioFactory -> shared Dio
                                                      -> AuthRepository
                                                      -> FeedbackTransport
                                                      -> HouseholdRemoteDataSource
```

The `Dio` is registered as a shared per-server singleton so every repository
and data source resolves the same instance and inherits the interceptor stack
— including token attachment — with no construction-order dependency. The
container owns the `Dio` and closes it on dispose; individual clients must not
close a `Dio` they share.

Interceptor order (see `register_server_network.dart` for the reasoning):
`NetworkLogInterceptor` → `TokenInterceptor` → `ClockSkewInterceptor`.

## Contents

- **`network/`** — `registerServerNetwork`, `NetworkScopeInstaller` and
  `TokenInterceptor` (token attachment).
- **`auth/`** — `AuthRepositoryImpl` (BetterAuth over the per-server Dio) and
  `TokenStorageService` (keyed by the stable `bgeServerId`).
