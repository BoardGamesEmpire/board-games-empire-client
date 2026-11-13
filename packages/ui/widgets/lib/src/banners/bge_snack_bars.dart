import 'package:flutter/material.dart';

/// SnackBar helpers for [ScaffoldMessengerState].
extension BgeSnackBars on ScaffoldMessengerState {
  /// Shows [message] in a SnackBar, replacing any bar already showing or
  /// waiting (#343).
  ///
  /// Cleared first because `showSnackBar` *queues*. An outcome is usually
  /// reported after something slow, so the control looks inert and people use
  /// it again; three taps stacked three confirmations that replayed for over
  /// fifteen seconds, long after the work was done. Only the newest outcome is
  /// true, and it is the only one worth showing. `clearSnackBars` rather than
  /// `removeCurrentSnackBar`: the latter merely promotes the next bar in the
  /// queue, which is the same bug one position along.
  ///
  /// The bar is the whole announcement, sighted and otherwise: Flutter's
  /// `snack_bar.dart` already wraps every bar in a live region, so do not add
  /// another, and do not pair it with `SemanticsService.announce` (#191).
  void replaceSnackBar(String message) {
    clearSnackBars();
    showSnackBar(SnackBar(content: Text(message)));
  }
}
