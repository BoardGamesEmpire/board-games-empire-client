import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/wcag_contrast.dart';

/// The text-selection highlight, and the two floors that bracket it (#322).
///
/// The highlight is a translucent tint painted *behind* text that keeps its
/// own colour — `TextSelectionThemeData` has no selected-text colour to pair
/// with it. So the tint can only ever subtract from the contrast the schemes
/// were authored to, and the alpha is a trade between two competing floors:
///
/// - raise it and the selection becomes easier to see, but the selected text
///   becomes harder to read;
/// - lower it and the text stays crisp, but the user cannot tell what they
///   have selected.
///
/// ## Why selected text is held to the large-text floor
///
/// It cannot be held to the schemes' body-text bars. Measured against the
/// full surface family, the worst unselected pair is 5.04:1 in light and
/// 7.49:1 in high-contrast light — 0.5 of headroom over the 4.5:1 and 7.0:1
/// bars those schemes are authored to. A tint faint enough to preserve that
/// headroom (alpha ≈ 0.08) renders at 1.11:1 against the surface, which is
/// not visible. There is no alpha that satisfies both, in any scheme, from
/// any accent role — so the choice is which floor to relax, not whether to.
///
/// Selected text is therefore held to the *large-text* floor rather than the
/// normal-text one, at the same AA/AAA split the schemes themselves use:
/// [Wcag.aaLargeText] in the standard schemes, [Wcag.aaaLargeText] in the
/// high-contrast pair. A deliberate, bounded relaxation for a transient,
/// user-initiated state — and the reason `bge_selection_test.dart` asserts
/// 3:1 and 4.5:1 rather than 4.5:1 and 7:1. Do not "fix" those upward
/// without re-reading this: they are unsatisfiable, not overlooked.
///
/// ## What this does *not* guarantee
///
/// One `selectionColor` serves the whole app, so the tint is invisible on any
/// background it matches. Measured over the authored schemes, the highlight
/// against its own background is 1.00:1 on `primary` — a `FilledButton`
/// label selects with no visible highlight at all — and 1.04–1.34:1 on
/// `secondary`, `tertiary`, `error` and `inverseSurface`. All below
/// [minVisibility].
///
/// This is not a tuning failure and no alpha fixes it: any single tint is
/// invisible on itself, and `TextSelectionThemeData` offers exactly one
/// colour. It is the same accepted trade as chrome being selectable at all
/// (#322) — the region reaches buttons and SnackBars, and on those the
/// selection is real, copied, and unhighlighted. [minVisibility] is
/// therefore a guarantee about the **surface family**, where body text
/// actually lives, and nothing wider. Fixing it properly means a
/// selection-aware text colour, which the framework does not expose.
abstract final class BgeSelection {
  /// Opacity of the selection tint over its surface.
  ///
  /// 0.28 is the value that leaves the most room on both floors at once: the
  /// worst selected-text pair lands at 3.46:1 (light) against a 3:1 floor and
  /// 4.92:1 (high-contrast dark) against a 4.5:1 one, with the faintest
  /// highlight at 1.43:1 against a [minVisibility] floor of 1.3:1.
  ///
  /// The framework's own default of 0.40 fails in all four: 2.92:1 in light
  /// and 2.95:1 in dark against 3:1, and 4.10:1 / 4.06:1 in the
  /// high-contrast pair against 4.5:1. Note it clears 3:1 in those last two —
  /// so the case for authoring this rests on the AAA floor above, not on the
  /// standard one.
  static const double tintAlpha = 0.28;

  /// Minimum contrast for text sitting on the highlight, standard schemes.
  ///
  /// See the class doc for why this is the large-text floor rather than the
  /// body-text bar the schemes otherwise clear.
  static const double minSelectedTextContrast = Wcag.aaLargeText;

  /// The same floor for the high-contrast pair, which is authored to AAA.
  ///
  /// A high-contrast user needs more from a selection, not the same: holding
  /// both pairs to 3:1 would have let the framework default through, since it
  /// clears 3:1 in the high-contrast schemes (4.10 and 4.06) and fails it
  /// only in light and dark. At [tintAlpha] the high-contrast pair measures
  /// 4.96 and 4.92, so this floor costs nothing and closes that hole.
  static const double minSelectedTextContrastHighContrast = Wcag.aaaLargeText;

  /// Minimum contrast between the highlight and the unselected **surface**.
  ///
  /// A project floor, not a WCAG one — no success criterion covers "can the
  /// user see which words are selected". It exists to catch the obvious
  /// regression: someone lowering [tintAlpha] to buy back text contrast until
  /// the highlight is invisible.
  ///
  /// Scoped to the surface family on purpose; see "What this does not
  /// guarantee" above for the backgrounds it deliberately says nothing about.
  static const double minVisibility = 1.3;

  /// The selection highlight for [scheme].
  ///
  /// Derived from `primary` rather than authored per-scheme so a palette swap
  /// carries it — the same reasoning the scrim in `bge_app.dart` is built on.
  /// One alpha clears every floor in all four schemes, so there is nothing
  /// per-scheme to author even though the floors themselves differ.
  static Color colorFor(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: tintAlpha);

  /// Whether [platform] gets the app-wide selection region (#322).
  ///
  /// Pointer platforms do; touch platforms do not. This is a platform
  /// question rather than a device one, and deliberately so: the framework
  /// already resolves the hybrid case a level below. A touchscreen laptop
  /// reports a desktop platform and so keeps the region — and gets no
  /// magnifier (`TextMagnifier.adaptiveMagnifierConfiguration` builds none
  /// off mobile) and no handles or toolbar after a drag (`SelectableRegion`
  /// takes the desktop branch), while `SelectableRegion`'s recognizers still
  /// dispatch on the live pointer kind, so a finger drag selects horizontally
  /// without stealing the scroll. Nothing here needs to know a touchscreen
  /// exists.
  ///
  /// The cost is the mirror case: an Android tablet driven by a mouse gets no
  /// region. Accepted.
  ///
  /// Read it from `Theme.of(context).platform`, not `defaultTargetPlatform` —
  /// the former is settable per-test through `ThemeData(platform:)` with no
  /// global mutation, and it is the same source `SelectionArea` consults for
  /// its handle controls, so the region and its controls cannot disagree.
  ///
  /// The switch is exhaustive on purpose: a platform added to Flutter should
  /// break the build here and force a decision, not inherit a default.
  static bool isEnabledOn(TargetPlatform platform) => switch (platform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
}
