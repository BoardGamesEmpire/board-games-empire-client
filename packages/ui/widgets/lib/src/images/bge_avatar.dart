import 'package:flutter/material.dart';
import 'package:ui/src/images/bge_thumbnail.dart';

/// A person's picture in a circle, or their initials when there is none (#547).
///
/// The fallback, in order: the picture at [imageUrl]; the [initials]; and,
/// only when there are no initials at all, [Icons.person_outline]. Initials
/// come first because they tell people apart on a roster, which an icon does
/// not. The initials show while the picture loads and again if it fails.
///
/// Decorative to a screen reader: every row that shows an avatar names the
/// person beside it, so the avatar adds nothing to say.
///
/// ## Web
///
/// A provider's picture host may send no CORS header, so on web the default
/// byte fetch would fail there. [WebHtmlElementStrategy.fallback] draws the
/// picture through an HTML image element when the fetch fails, and costs
/// nothing when it succeeds. Native ignores the parameter. The same choice as
/// `BgeThumbnail`'s, which measured it for #44.
///
/// ## Caching and size
///
/// None beyond Flutter's in-memory image cache. The picture is decoded no
/// larger than [BgeThumbnail.decodeHeadroom] times its drawn size each way,
/// in device pixels, keeping its shape, as `BgeThumbnail`'s is and for the
/// same reasons: an uploaded picture can be far larger than a 40dp circle,
/// and a roster draws many at once.
class BgeAvatar extends StatelessWidget {
  /// Creates an avatar of [imageUrl], of [initials], or of an icon.
  const BgeAvatar({
    required this.initials,
    this.imageUrl,
    this.size = defaultSize,
    super.key,
  });

  /// The diameter a roster row uses.
  static const double defaultSize = 40;

  /// Key on the image, so a test can find it.
  static const Key imageKey = Key('bge_avatar.image');

  /// The initials' font size, as a share of the diameter.
  static const double _initialsShare = 0.4;

  /// How much of the diameter the initials may fill, each way.
  static const double _initialsFit = 0.7;

  /// The icon's size, as a share of the diameter.
  static const double _iconShare = 0.6;

  /// One or two letters, from `personInitials`. Null shows an icon.
  final String? initials;

  /// The picture's address. Null shows the fallback.
  final String? imageUrl;

  /// The diameter.
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final imageUrl = this.imageUrl;
    final decodeBound =
        (size *
                MediaQuery.devicePixelRatioOf(context) *
                BgeThumbnail.decodeHeadroom)
            .ceil();
    final fallback = _Fallback(
      initials: initials,
      size: size,
      color: scheme.onSecondaryContainer,
    );

    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: ClipOval(
          child: ColoredBox(
            color: scheme.secondaryContainer,
            child: imageUrl == null
                ? fallback
                : Image(
                    key: imageKey,
                    image: ResizeImage(
                      NetworkImage(
                        imageUrl,
                        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                      ),
                      width: decodeBound,
                      height: decodeBound,
                      policy: ResizeImagePolicy.fit,
                    ),
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                    frameBuilder: (
                      context,
                      child,
                      frame,
                      wasSynchronouslyLoaded,
                    ) => frame == null ? fallback : child,
                    errorBuilder: (context, error, stackTrace) => fallback,
                  ),
          ),
        ),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({
    required this.initials,
    required this.size,
    required this.color,
  });

  final String? initials;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final initials = this.initials;
    if (initials == null) {
      return Center(
        child: Icon(
          Icons.person_outline,
          size: size * BgeAvatar._iconShare,
          color: color,
        ),
      );
    }

    // The letters keep their natural size, which follows the text scale, and
    // shrink only when they would outgrow the circle, as at 200% text:
    // a Text cannot wrap to fit one. `scaleDown`, not the default `contain`,
    // which would also scale a short label up to fill the box.
    return Center(
      child: SizedBox.square(
        dimension: size * BgeAvatar._initialsFit,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            initials,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: color,
              fontSize: size * BgeAvatar._initialsShare,
            ),
          ),
        ),
      ),
    );
  }
}
