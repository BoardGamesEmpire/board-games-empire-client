/// Reusable, presentation-only widgets.
///
/// Convention for this package: widgets receive localized strings and state as
/// parameters — no localization delegates, no blocs, no repository types.
/// Wiring those is the consuming layer's job (`app_shell` for shell chrome,
/// feature packages for their screens).
///
/// Everything here is justified by duplication that already existed, and the
/// migration is complete rather than aspirational — `BgePage` is used by all
/// 12 page-shaped screens, `BgeSubmitButton` by all 6 submit controls,
/// `BgeTextField` by every form field in 5 files (#165).
///
/// Two surfaces deliberately do NOT use `BgePage`: `CrashReportPrompt` and
/// `BuildErrorView` render above the navigator with no `Scaffold` of their
/// own, so they are not pages. They share only the width constraint, which
/// they take from `BgeTokens.contentMaxWidth`.
///
/// New widgets belong here once a second call site wants them — not in
/// anticipation of one.
library;

export 'src/banners/bge_inline_banner.dart';
export 'src/banners/unverified_session_banner.dart';
export 'src/buttons/bge_submit_button.dart';
export 'src/forms/bge_text_field.dart';
export 'src/layout/bge_page.dart';
