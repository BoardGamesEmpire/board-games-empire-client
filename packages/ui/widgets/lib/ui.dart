/// Reusable, presentation-only widgets (#98 hosts the first one).
///
/// Convention for this package: widgets receive localized strings and
/// state as parameters — no localization delegates, no blocs, no
/// repository types. Wiring those is the consuming layer's job
/// (app_shell for shell chrome, feature packages for their screens).
library;

export 'src/banners/unverified_session_banner.dart';
