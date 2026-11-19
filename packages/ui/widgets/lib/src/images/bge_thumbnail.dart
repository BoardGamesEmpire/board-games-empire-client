import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A remote image at one fixed square size, or a placeholder while it loads,
/// when it fails, and when there is none.
///
/// ## Cropping
///
/// The square crops its image to fill it, and anchors the crop at the top,
/// because box art prints its title there: a portrait cover loses its
/// bottom, not its name. Every caller gets this. [whole] draws the image
/// uncropped instead, for a cover shown on its own, anchored at the top start
/// so it shares the top edge of the title beside it, or the start edge of the
/// title and facts below it (#937).
///
/// Moved here from the collection list (#44) when the game catalog (#42)
/// wanted the same thumbnail.
///
/// ## Web
///
/// The URLs are third-party. Measured in a browser for #44: BoardGameGeek's
/// image host sends no CORS header, so on web the default byte fetch
/// ([WebHtmlElementStrategy.never]) fails there.
/// [WebHtmlElementStrategy.fallback] is the narrowest strategy that renders
/// it. IGDB's host does send the header, so its images still go through the
/// byte fetch, and only a failed fetch costs an HTML element; `prefer` would
/// put every image in one. Native ignores the parameter. An image shown
/// through that element is decoded by the browser, so the decode bound
/// below does not reach it.
///
/// ## Caching and size
///
/// No disk cache: Flutter's in-memory image cache only, so an offline
/// restart shows placeholders until #449.
///
/// Decoded no larger than [decodeHeadroom] times its drawn size each way, in
/// device pixels, keeping its shape ([ResizeImagePolicy.fit], which never
/// enlarges). A full-size image, which the game detail draws (#42), is held
/// to a few megabytes rather than the tens a BoardGameGeek original decodes
/// to. A thumbnail host's images (measured for #44: IGDB 264×352,
/// BoardGameGeek within 200×150) are no larger than that bound at a list
/// row's size, so they decode as sent.
///
/// Twice, not once: under `BoxFit.cover` an image's shorter side has to
/// span the square, and a bound of the square itself would leave that side
/// short, and blurred, for any image that is not square. Twice keeps an
/// image sharp up to 2:1. The bound holds in both modes.
///
/// Decorative to a screen reader: the text beside it names what it shows.
class BgeThumbnail extends StatelessWidget {
  /// Creates a thumbnail of [url], or of nothing.
  const BgeThumbnail({
    this.url,
    this.extent = listExtent,
    this.placeholderIcon = Icons.image_outlined,
    this.placeholderKey,
    this.whole = false,
    super.key,
  });

  /// Material 3's list image size.
  static const double listExtent = 56;

  /// How many times its drawn size an image may be decoded at, each way.
  static const int decodeHeadroom = 2;

  /// The body text scale from which a list row that leads with a thumbnail
  /// aligns it by [ListTileTitleAlignment.titleHeight] (#647).
  ///
  /// At default sizes [ListTileTitleAlignment.top] keeps every row's
  /// thumbnail at the same height, where `titleHeight` would put a short
  /// row's at 8dp and a wrapped row's at 16dp. From this scale a row with a
  /// facts line is tall enough that `titleHeight` puts the thumbnail 16dp
  /// down, level with the title's first line, and a row with a title alone,
  /// held to [minTileHeightOf], has it centred at 8dp.
  static const double titleHeightTextScale = 1.3;

  /// The least height of a list row that leads with a thumbnail (#647): the
  /// thumbnail with [BgeTokens.spaceSm] above and below it. That is Material
  /// 3's `ListTile.minVerticalPadding`, so a row with a title alone holds its
  /// thumbnail inside its outline, as a tile sizes a one-line row without
  /// counting the leading's height. Pass it as the tile's `minTileHeight`.
  static double minTileHeightOf(BuildContext context) =>
      listExtent + 2 * BgeTokens.of(context).spaceSm;

  /// How a list row that leads with a thumbnail sets it beside its title
  /// (#647). Pass it as the tile's `titleAlignment`.
  static ListTileTitleAlignment titleAlignmentOf(BuildContext context) {
    // Measured at the row title's size, so a nonlinear scaler is read where
    // it applies.
    final size =
        Theme.of(context).textTheme.bodyLarge?.fontSize ?? kDefaultFontSize;
    final scale = MediaQuery.textScalerOf(context).scale(size) / size;
    return scale >= titleHeightTextScale
        ? ListTileTitleAlignment.titleHeight
        : ListTileTitleAlignment.top;
  }

  /// The image's address. Null shows the placeholder.
  final String? url;

  /// The side of the square.
  final double extent;

  /// Drawn on the placeholder.
  final IconData placeholderIcon;

  /// Key on every placeholder, so a test can find one.
  final Key? placeholderKey;

  /// Draws the image uncropped: no crop, and no letterbox bars. It fits
  /// inside the square, anchored at the top start (the top left, or the top
  /// right in a right-to-left language), with transparent space around it,
  /// and the rounded clip follows the image rather than the square. The
  /// placeholder still fills the square. Known limit: an image smaller than
  /// the square on both sides is drawn at its own size, not enlarged to fit,
  /// as an `Image` with no size does under loose constraints.
  final bool whole;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    final decodeBound =
        (extent * MediaQuery.devicePixelRatioOf(context) * decodeHeadroom)
            .ceil();
    final placeholder = SizedBox.expand(
      child: _Placeholder(key: placeholderKey, icon: placeholderIcon),
    );

    final radius = BorderRadius.circular(BgeTokens.of(context).radiusSm);
    final image = url == null
        ? null
        : Image(
            image: ResizeImage(
              NetworkImage(
                url,
                webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
              ),
              width: decodeBound,
              height: decodeBound,
              policy: ResizeImagePolicy.fit,
            ),
            fit: whole ? BoxFit.contain : BoxFit.cover,
            alignment: whole
                ? AlignmentDirectional.topStart
                : Alignment.topCenter,
            excludeFromSemantics: true,
            // Keyed on the first frame, not on load progress: a request
            // that has no response yet reports no progress at all.
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                frame == null ? placeholder : child,
            errorBuilder: (context, error, stackTrace) => placeholder,
          );

    return SizedBox.square(
      dimension: extent,
      child: whole
          // Loose constraints, so the image keeps its shape and the clip
          // follows it; the placeholder expands to the square.
          ? Align(
              alignment: AlignmentDirectional.topStart,
              child: ClipRRect(
                borderRadius: radius,
                child: image ?? placeholder,
              ),
            )
          : ClipRRect(borderRadius: radius, child: image ?? placeholder),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(child: Icon(icon, color: scheme.onSurfaceVariant)),
    );
  }
}
