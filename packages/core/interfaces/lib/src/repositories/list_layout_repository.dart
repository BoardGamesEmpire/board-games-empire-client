import 'package:models/domain.dart';

/// The layout each list screen was last left in, for the signed-in user
/// (#710).
///
/// Kept on this device, per user, and never synced: a phone and a desktop
/// can reasonably want different layouts, and a shared device's users each
/// keep their own choice.
abstract class ListLayoutRepository {
  /// The layout stored for [screen], or null when the user hasn't chosen
  /// one (or the stored name isn't one this client knows).
  Future<ListLayout?> read(ListLayoutScreen screen);

  /// Stores [layout] as [screen]'s choice, replacing any earlier one.
  Future<void> write(ListLayoutScreen screen, ListLayout layout);
}

/// A screen's layout as its toggle holds it, thumbnails or not (#710).
///
/// Games and Collection both keep the choice as a bool, `true` for
/// [ListLayout.thumbnails] and `false` for [ListLayout.list], so the mapping
/// is written here once rather than in each screen.
extension ListLayoutThumbnails on ListLayoutRepository {
  /// Whether [screen] was left in thumbnails, or null when the user hasn't
  /// chosen (see [ListLayoutRepository.read]).
  Future<bool?> readThumbnails(ListLayoutScreen screen) async {
    final layout = await read(screen);
    return layout == null ? null : layout == ListLayout.thumbnails;
  }

  /// Stores thumbnails as [screen]'s choice when [thumbnails] is true, and
  /// the list when it is false.
  Future<void> writeThumbnails(
    ListLayoutScreen screen, {
    required bool thumbnails,
  }) => write(screen, thumbnails ? ListLayout.thumbnails : ListLayout.list);
}
