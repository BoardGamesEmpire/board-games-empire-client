import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A remote image at one fixed square size, or a placeholder while it loads,
/// when it fails, and when there is none.
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
/// image sharp up to 2:1.
///
/// Decorative to a screen reader: the text beside it names what it shows.
class BgeThumbnail extends StatelessWidget {
  /// Creates a thumbnail of [url], or of nothing.
  const BgeThumbnail({
    this.url,
    this.extent = listExtent,
    this.placeholderIcon = Icons.image_outlined,
    this.placeholderKey,
    super.key,
  });

  /// Material 3's list image size.
  static const double listExtent = 56;

  /// How many times its drawn size an image may be decoded at, each way.
  static const int decodeHeadroom = 2;

  /// The image's address. Null shows the placeholder.
  final String? url;

  /// The side of the square.
  final double extent;

  /// Drawn on the placeholder.
  final IconData placeholderIcon;

  /// Key on every placeholder, so a test can find one.
  final Key? placeholderKey;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    final decodeBound =
        (extent * MediaQuery.devicePixelRatioOf(context) * decodeHeadroom)
            .ceil();
    final placeholder = _Placeholder(
      key: placeholderKey,
      icon: placeholderIcon,
    );

    return SizedBox.square(
      dimension: extent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(BgeTokens.of(context).radiusSm),
        child: url == null
            ? placeholder
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
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                // Keyed on the first frame, not on load progress: a request
                // that has no response yet reports no progress at all.
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                    frame == null ? placeholder : child,
                errorBuilder: (context, error, stackTrace) => placeholder,
              ),
      ),
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
