import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/list_layout_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

void main() {
  late ServerDatabase db;
  late ListLayoutRepository layouts;

  setUp(() {
    db = inMemoryServerDatabase();
    layouts = ListLayoutRepositoryImpl(db, userId: 'a');
  });

  tearDown(() async => db.close());

  test('nothing stored reads null', () async {
    expect(await layouts.read(ListLayoutScreen.games), isNull);
  });

  test('a write is read back', () async {
    await layouts.write(ListLayoutScreen.games, ListLayout.thumbnails);

    expect(await layouts.read(ListLayoutScreen.games), ListLayout.thumbnails);
  });

  test('a second write replaces the first', () async {
    await layouts.write(ListLayoutScreen.games, ListLayout.thumbnails);
    await layouts.write(ListLayoutScreen.games, ListLayout.list);

    expect(await layouts.read(ListLayoutScreen.games), ListLayout.list);
  });

  test('each screen keeps its own', () async {
    await layouts.write(ListLayoutScreen.games, ListLayout.thumbnails);
    await layouts.write(ListLayoutScreen.collection, ListLayout.list);

    expect(await layouts.read(ListLayoutScreen.games), ListLayout.thumbnails);
    expect(await layouts.read(ListLayoutScreen.collection), ListLayout.list);
  });

  test("one user's choice is not another's", () async {
    final other = ListLayoutRepositoryImpl(db, userId: 'b');

    await layouts.write(ListLayoutScreen.games, ListLayout.thumbnails);

    expect(await other.read(ListLayoutScreen.games), isNull);
    await other.write(ListLayoutScreen.games, ListLayout.list);
    expect(await layouts.read(ListLayoutScreen.games), ListLayout.thumbnails);
    expect(await other.read(ListLayoutScreen.games), ListLayout.list);
  });

  test('an unknown stored name reads null', () async {
    await db.customInsert(
      'INSERT INTO list_layouts (user_id, screen, layout) '
      "VALUES ('a', 'games', 'mosaic')",
    );

    expect(await layouts.read(ListLayoutScreen.games), isNull);
  });
}
