import 'package:events/src/widgets/destructive_button_style.dart';
import 'package:flutter/material.dart';

/// Asks whether to go ahead, and answers whether the user did: one dialog
/// for the date writes that ask first and for Reopen (#502), so they lay out
/// alike. The caller gives the copy. A [destructive] action is drawn in the
/// error colour, as Delete's is.
///
/// Scrollable, since at 2.0 text a long title and the body can outgrow a
/// phone's height. Buttons that don't fit side by side stack.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String keepLabel,
  required String confirmLabel,
  bool destructive = false,
  Key? keepKey,
  Key? confirmKey,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: keepKey,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(keepLabel),
        ),
        TextButton(
          key: confirmKey,
          style: destructive ? destructiveButtonStyle(dialogContext) : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
