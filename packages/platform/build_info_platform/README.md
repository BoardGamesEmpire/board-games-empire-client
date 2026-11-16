# build_info_platform

Shared build metadata for Board Games Empire.

Provides `PackageInfoBuildInfoReader`, the concrete implementation of the
`BuildInfoReader` contract from `interfaces`, backed by the
`package_info_plus` plugin.

Like `connectivity_platform`, this package is **shared** by the native and
web composition roots. `package_info_plus` is a federated plugin (js_interop
on web), so a single package resolves to the right platform implementation
at build time without dependency bleed.

## Behaviour

- **Source.** On native (mobile and desktop) the values come from the Android
  manifest or the macOS bundle; on web, from Flutter's generated
  `version.json`. Both are derived from the app pubspec's `version:` (#35).
- **Never throws.** Any source failure (a missing plugin, a channel error, a
  missing or unreachable `version.json`) resolves to `BuildInfo.unknown`.
- **Never hangs.** The read is bounded by `readTimeout` (default
  `defaultReadTimeout`, five seconds). The read blocks `createRootContainer`
  on the boot hot path, so a wedged method-channel read or `version.json`
  fetch degrades to `BuildInfo.unknown` instead of stalling the boot.
- **Silent.** The package has no observability dependency, and the degraded
  value is itself the visible signal: feedback reports and the about screen
  render "Unknown …".

## Testing

The constructor's `packageInfoReader` is the injectable source seam, so the
contract is driven with a synthetic `PackageInfo`; `package_info_plus` itself
is never mocked. See `test/package_info_build_info_reader_test.dart`, which
runs on the VM.

Part of the Board Games Empire client monorepo; not published to pub.dev.
