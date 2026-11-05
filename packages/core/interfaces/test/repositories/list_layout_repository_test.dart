import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:test/test.dart';

/// Keeps each screen's layout in memory.
class _MemoryLayouts implements ListLayoutRepository {
  final stored = <ListLayoutScreen, ListLayout>{};

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async => stored[screen];

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async =>
      stored[screen] = layout;
}

void main() {
  group('ListLayoutThumbnails', () {
    late _MemoryLayouts layouts;

    setUp(() => layouts = _MemoryLayouts());

    test('reads no choice as null', () async {
      expect(await layouts.readThumbnails(ListLayoutScreen.games), isNull);
    });

    test('reads thumbnails as true and the list as false', () async {
      layouts.stored[ListLayoutScreen.games] = ListLayout.thumbnails;
      layouts.stored[ListLayoutScreen.collection] = ListLayout.list;

      expect(await layouts.readThumbnails(ListLayoutScreen.games), isTrue);
      expect(
        await layouts.readThumbnails(ListLayoutScreen.collection),
        isFalse,
      );
    });

    test('writes true as thumbnails and false as the list, for that screen '
        'alone', () async {
      await layouts.writeThumbnails(ListLayoutScreen.games, true);

      expect(layouts.stored, {ListLayoutScreen.games: ListLayout.thumbnails});

      await layouts.writeThumbnails(ListLayoutScreen.games, false);
      await layouts.writeThumbnails(ListLayoutScreen.collection, true);

      expect(layouts.stored, {
        ListLayoutScreen.games: ListLayout.list,
        ListLayoutScreen.collection: ListLayout.thumbnails,
      });
    });
  });
}
