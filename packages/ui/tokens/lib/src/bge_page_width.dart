import 'package:ui_tokens/src/bge_tokens.dart';

/// Which measure caps a page's content column, resolved against a [BgeTokens]
/// instance.
///
/// Lives here rather than beside `BgePage` for the reason `BgeSpacingStep`
/// does: the mapping from a name to a token belongs next to the tokens it
/// maps (#212). Each value is a *measure*, applied as a maximum. None of them
/// is a breakpoint; see [BgeTokens.paneMaxWidth] for why the two are kept
/// apart.
enum BgePageWidth {
  /// A reading measure ([BgeTokens.contentMaxWidth]). Forms and prose — the
  /// default, and correct for most screens.
  form,

  /// A wider measure ([BgeTokens.paneMaxWidth]) for list and pane surfaces,
  /// whose rows are a label plus a trailing control rather than a line to be
  /// read. Still capped: no surface stretches to the width of a monitor.
  pane;

  /// This measure's width in [tokens].
  double resolve(BgeTokens tokens) => switch (this) {
    BgePageWidth.form => tokens.contentMaxWidth,
    BgePageWidth.pane => tokens.paneMaxWidth,
  };
}
