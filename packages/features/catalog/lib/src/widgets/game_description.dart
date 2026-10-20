import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

/// A game's description, rendered as Markdown (#472).
///
/// The server sends descriptions as CommonMark with GitHub's extensions,
/// already sanitized: raw HTML stripped, and a link or image whose address
/// is not `http`, `https` or `mailto` reduced to its text. This is the second
/// layer behind that, not a replacement for it.
///
/// ## Raw HTML is never rendered
///
/// Measured with a probe against the pinned Flutter (#42): the renderer has
/// no HTML path. An HTML block is dropped, and inline HTML shows as the
/// literal text of its tags. The inline HTML syntax is left out of the
/// extension set anyway, so the tags are plain text from the start rather
/// than an HTML node the renderer happens to print.
///
/// ## Links go outside the app
///
/// Every link tap reaches one callback, whatever its scheme, which the same
/// probe confirmed. Only `http`, `https` and `mailto` are passed on to
/// [onOpenLink]; any other tap does nothing.
///
/// ## Images
///
/// An `http` or `https` image is fetched, falling back to an HTML element on
/// web where the host sends no CORS header, as the thumbnails do. Any other
/// address, and an image that fails, shows its description instead.
///
/// Decoded no wider than the display, in device pixels, keeping its shape
/// ([ResizeImagePolicy.fit], which never enlarges), so a full-size original
/// is not held at tens of megabytes. The display, not the laid-out width:
/// measured against the pinned Flutter, a bound that follows the layout
/// fetches and decodes the image again at every new width, as a desktop
/// window is resized. Drawn the same either way.
class GameDescription extends StatelessWidget {
  const GameDescription({
    required this.markdown,
    required this.onOpenLink,
    super.key,
  });

  final String markdown;

  /// Opens a link the user tapped, outside the app.
  final void Function(Uri uri) onOpenLink;

  /// GitHub's extensions, less inline HTML.
  static final md.ExtensionSet extensions = md.ExtensionSet(
    md.ExtensionSet.gitHubFlavored.blockSyntaxes,
    [
      for (final syntax in md.ExtensionSet.gitHubFlavored.inlineSyntaxes)
        if (syntax is! md.InlineHtmlSyntax) syntax,
    ],
  );

  /// The schemes an image may be fetched from.
  static const Set<String> fetchableSchemes = {'http', 'https'};

  /// The schemes a link may be opened with.
  static const Set<String> _openableSchemes = {...fetchableSchemes, 'mailto'};

  /// [href] as a link the app may open, or null when it may not.
  static Uri? openableLink(String? href) {
    if (href == null) return null;
    final uri = Uri.tryParse(href);
    if (uri == null) return null;
    return _openableSchemes.contains(uri.scheme.toLowerCase()) ? uri : null;
  }

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: markdown,
    extensionSet: extensions,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
    onTapLink: (text, href, title) {
      final uri = openableLink(href);
      if (uri != null) onOpenLink(uri);
    },
    imageBuilder: (uri, title, alt) => _DescriptionImage(uri: uri, alt: alt),
  );
}

class _DescriptionImage extends StatelessWidget {
  const _DescriptionImage({required this.uri, this.alt});

  final Uri uri;
  final String? alt;

  @override
  Widget build(BuildContext context) {
    final alt = this.alt;
    final fallback = alt == null || alt.isEmpty
        ? const SizedBox.shrink()
        : Text(GameCatalogLocalizations.of(context).catalogImageAlt(alt));

    if (!GameDescription.fetchableSchemes.contains(uri.scheme.toLowerCase())) {
      return fallback;
    }

    return Image(
      image: ResizeImage(
        NetworkImage(
          uri.toString(),
          webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        ),
        width: View.of(context).display.size.width.ceil(),
        policy: ResizeImagePolicy.fit,
      ),
      semanticLabel: alt,
      excludeFromSemantics: alt == null || alt.isEmpty,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}
