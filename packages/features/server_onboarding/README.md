# server_onboarding

First-run server-add feature (#36): discover a Board Games Empire server,
negotiate client/server version compatibility, then persist and activate it.

## Flow

`ServerOnboardingBloc` drives:

1. normalize + validate the entered URL (local; never touches the network);
2. connectivity fast-fail (#9) — surfaced before any fetch;
3. `WellKnownClient.fetchIdentity` discovery;
4. `VersionNegotiator.negotiate` (#13) — a mismatch **never** persists;
5. `ServerOrchestrator.addAndActivateServer` — persist + activate.

Failures are sealed *kinds* (with payloads where a message needs
interpolation); localization happens in the widget layer, keeping the bloc
locale-free (#33).

## URL rules

Input is trimmed; `https://` is assumed when no scheme is given. Plain `http`
is allowed only for loopback and RFC 1918 hosts (self-hosting / LAN); `https`
is required otherwise. Path prefixes are preserved (reverse-proxy
deployments); query/fragment and a trailing slash are dropped.

## Wiring

`app_shell` owns construction: it supplies the screen to the `/server-add`
route, provides the bloc from the root container, and advances bootstrap via
`AppBootstrapCubit.onServerRegistered()` on success. The route is native-only
in practice — web is same-origin and never reaches it.

## Accessibility

Labeled fields (never hint-only), failure and in-flight state in `liveRegion`
semantics, submit disabled (not hidden) while in flight, full keyboard
operability.
