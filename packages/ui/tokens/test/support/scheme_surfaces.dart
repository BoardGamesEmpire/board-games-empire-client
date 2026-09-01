/// The backgrounds and text roles the palette's contrast guarantees cover.
///
/// Shared rather than restated per suite. `bge_color_schemes_test.dart`
/// asserts body text is legible on these; `bge_selection_test.dart` asserts
/// it stays legible once a selection highlight is composited over them, and
/// documents itself as covering "the same family". That claim was two
/// copy-pasted literals until it became this file — adding a surface role to
/// one list and not the other would have quietly narrowed the selection
/// guarantee while both suites stayed green.
library;

import 'package:flutter/material.dart';

/// Every surface role body text can legitimately be painted on.
///
/// Deliberately more than `surface`: cards, sheets and banners paint one of
/// the container roles, and solving the on-roles against the bare surface
/// alone left the top containers failing while a pair test still read green.
List<(String, Color)> surfaceFamily(ColorScheme s) => [
  ('surface', s.surface),
  ('surfaceDim', s.surfaceDim),
  ('surfaceBright', s.surfaceBright),
  ('surfaceContainerLowest', s.surfaceContainerLowest),
  ('surfaceContainerLow', s.surfaceContainerLow),
  ('surfaceContainer', s.surfaceContainer),
  ('surfaceContainerHigh', s.surfaceContainerHigh),
  ('surfaceContainerHighest', s.surfaceContainerHighest),
];

/// The body-text roles that land on [surfaceFamily].
List<(String, Color)> bodyTextRoles(ColorScheme s) => [
  ('onSurface', s.onSurface),
  ('onSurfaceVariant', s.onSurfaceVariant),
];
