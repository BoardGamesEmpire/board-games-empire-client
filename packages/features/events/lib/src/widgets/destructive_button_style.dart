import 'package:flutter/material.dart';

/// The style of a text button for an action that takes something away or
/// tells people something that can't be unsaid, such as a delete, a decline,
/// a cancel or a removal: the error colour, as Delete's is. Shared by the
/// date dialogs and the cancel-reason dialog so they read alike.
ButtonStyle destructiveButtonStyle(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error);
