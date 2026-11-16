## 0.0.1

Initial internal release (#196).

* `BuildInfoReader` shared implementation `PackageInfoBuildInfoReader`,
  wrapping the federated `package_info_plus` plugin so one package serves
  both the native and web composition roots. It replaces the identical
  copies that `native_platform` and `web_platform` each carried.
* Never throws and never hangs: a failed or timed-out read resolves to
  `BuildInfo.unknown`.
