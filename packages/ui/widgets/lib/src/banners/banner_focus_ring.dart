import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// [style], with the keyboard focus ring (#644) in [color] at [placement], on
/// the shape of [app]: the app theme's style for the same kind of button.
///
/// For a button on a banner's toned container. The app's ring is `primary`,
/// which no toned container was solved against (2.92:1 on the dark error and
/// tertiary containers), so the ring takes the banner's foreground, the
/// colour that container's own content is solved against. The shape and the
/// rest of [app] fill what [style] leaves unset, so the banner's buttons
/// can't drift from the app's. With no app shape to follow, as under a theme
/// that isn't `BgeTheme`, there is no ring to draw, and [style] comes back
/// as it was.
///
/// Shared by the banners in this directory. Not exported.
ButtonStyle withBannerFocusRing(
  ButtonStyle style, {
  required ButtonStyle? app,
  required BgeButtonFocusRingPlacement placement,
  required Color color,
}) {
  final shape = app?.shape?.resolve(const <WidgetState>{});
  if (shape == null) return style;
  return style
      .copyWith(
        backgroundBuilder: BgeButtonFocusRing.builder(
          shape,
          placement: placement,
          color: color,
        ),
      )
      .merge(app);
}
