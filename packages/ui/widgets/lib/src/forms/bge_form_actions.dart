import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../banners/bge_inline_banner.dart';

/// A form's failed submit, shown by [BgeFormActions].
///
/// A failure only: a success on these forms takes the user off the screen,
/// so its confirmation is a SnackBar that outlives the route (STYLE_GUIDE,
/// "Error and outcome surfaces").
class BgeFormFailure {
  /// Creates a failure outcome.
  const BgeFormFailure({required this.message, required this.title, this.key});

  /// What went wrong. Already localized.
  final String message;

  /// The banner's heading, naming the operation that failed.
  ///
  /// ## The rule (#211)
  ///
  /// **Title an operation's failures when some of its messages state only a
  /// cause.** "Could not reach the server. Check your connection." is true of
  /// every request the app makes; on its own it never says that *signing in*
  /// failed, and the reader is left to infer it. "Something went wrong
  /// creating your household" names the operation already, and a heading
  /// above it would say the same thing twice.
  ///
  /// Decided per operation, not per message: a banner whose heading comes and
  /// goes with the failure kind would read as two different surfaces. Today:
  ///
  /// | Operation | Title |
  /// | --- | --- |
  /// | Add a server | "Couldn't add server" |
  /// | Sign in | "Couldn't sign in" |
  /// | Create an account | "Couldn't create account" |
  /// | Create a household | none |
  ///
  /// Always titling was the uniform option, but it adds a redundant line to
  /// the tallest thing on a small screen: a titled banner measured 240dp at
  /// 1.0 text scale (#228). Never titling was the shortest, and the one that
  /// leaves auth's bare causes unexplained.
  ///
  /// **Required, and nullable.** Every call site passes it, `null` included,
  /// so leaving a failure untitled is a decision someone wrote down rather
  /// than a parameter nobody noticed.
  final String? title;

  /// Key on the banner, for a test to find it by.
  final Key? key;
}

/// A form's primary action, with the outcome of its last submit directly
/// above it (#211, #227).
///
/// ```dart
/// BgeFormActions(
///   failure: failure == null
///       ? null
///       : BgeFormFailure(
///           title: l10n.serverAddErrorTitle,
///           message: _failureMessage(l10n, failure),
///         ),
///   action: BgeSubmitButton(
///     label: l10n.serverAddSubmit,
///     submitting: inProgress,
///     onPressed: _submit,
///   ),
/// )
/// ```
///
/// ## Why the outcome sits on the action
///
/// The outcome answers the button the user just pressed, so it belongs where
/// they pressed it. The forms disagreed (#227): server-add put its banner
/// above the submit, and auth and create-household put theirs at the top of
/// the page. At the top, a user who had scrolled down to reach the button had
/// to be scrolled away from it to read the answer. Measured on auth at
/// 320×400 and 200% text, scrolled to the end of the page: with the banner at
/// the top, the submit's top edge ended at 474 in the 400dp viewport, wholly
/// below the window. Above the submit, it starts at 386, directly beneath the
/// banner.
///
/// On create-household that long reveal was also the one a tap cuts short
/// (#233): with the real theme, the same scenario left its banner at −227,
/// off screen. Above the submit it lands at 16.
///
/// ## What it owns
///
/// - **The gap** between outcome and action: one medium step.
/// - **The measure**: the banner is exactly as wide as the action, whether or
///   not the column around it stretches its children.
/// - **The title rule**, through [BgeFormFailure.title].
///
/// ## What it does not own
///
/// **Reveal and announcement.** Those stay in [BgeInlineBanner], and this
/// passes it nothing new: a banner outside any form still needs them, and a
/// second mechanism here would be one more place for them to disagree.
///
/// **Where the action sits.** A form places this where its submit already
/// was. A page that pins its action ([BgePage.footer]) may pass this as the
/// footer instead, when the screen holds the state that drives it.
class BgeFormActions extends StatelessWidget {
  /// Creates the action area.
  const BgeFormActions({required this.action, this.failure, super.key});

  /// The submit control, normally a [BgeSubmitButton].
  final Widget action;

  /// The failure to show above [action], or null when there is none.
  ///
  /// Retiring it is the caller's job, as it is for any banner: a failure
  /// stops applying when the user edits what it complains about.
  final BgeFormFailure? failure;

  @override
  Widget build(BuildContext context) {
    final failure = this.failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (failure != null) ...[
          BgeInlineBanner(
            key: failure.key,
            tone: BgeBannerTone.error,
            title: failure.title,
            message: failure.message,
          ),
          const BgeGap.md(),
        ],
        action,
      ],
    );
  }
}
