/// Reusable, presentation-only widgets.
///
/// Convention for this package: widgets receive localized strings and state as
/// parameters — no localization delegates, no blocs, no repository types.
/// Wiring those is the consuming layer's job (`app_shell` for shell chrome,
/// feature packages for their screens).
///
/// Everything here is justified by duplication that already existed. The four
/// core widgets replaced, respectively, 11, 4, 3 and 2 hand-rolled copies
/// across the feature packages (#165). New widgets belong here once a second
/// call site wants them — not in anticipation of one.
library;

export 'src/banners/bge_inline_banner.dart';
export 'src/banners/unverified_session_banner.dart';
export 'src/buttons/bge_submit_button.dart';
export 'src/forms/bge_text_field.dart';
export 'src/layout/bge_page.dart';
