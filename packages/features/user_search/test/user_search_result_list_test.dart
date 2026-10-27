import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

class _MockUserSearchBloc extends MockBloc<UserSearchEvent, UserSearchState>
    implements UserSearchBloc {}

const _ana = UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B');
const _bo = UserSummary(id: 'u_3', username: 'bo');

/// The caller's own key for a row, as the household invite screen and the
/// event create form each pass theirs.
Key _rowKey(String userId) => Key('test.result_$userId');

/// What a user search shows (#455, #499): the bloc above it is parked in each
/// state in turn, and the rows are the caller's to key, mark picked and tap.
void main() {
  late _MockUserSearchBloc bloc;

  setUp(() {
    bloc = _MockUserSearchBloc();
  });

  /// Draws the list with [bloc] parked in [state]. [picked] answers `isPicked`
  /// and [onPick] takes the taps, unless [sending], when the caller passes
  /// none.
  Future<void> pumpList(
    WidgetTester tester,
    UserSearchState state, {
    Set<String> picked = const {},
    void Function(UserSummary user)? onPick,
    bool sending = false,
  }) {
    whenListen(
      bloc,
      const Stream<UserSearchState>.empty(),
      initialState: state,
    );
    return tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: UserSearchLocalizations.localizationsDelegates,
        supportedLocales: UserSearchLocalizations.supportedLocales,
        home: Scaffold(
          body: BlocProvider<UserSearchBloc>.value(
            value: bloc,
            child: UserSearchResultList(
              isPicked: (user) => picked.contains(user.id),
              onPick: sending ? null : (onPick ?? (_) {}),
              resultKey: _rowKey,
            ),
          ),
        ),
      ),
    );
  }

  ListTile row(WidgetTester tester, String userId) =>
      tester.widget<ListTile>(find.byKey(_rowKey(userId)));

  Finder checkIn(String userId) => find.descendant(
    of: find.byKey(_rowKey(userId)),
    matching: find.byIcon(Icons.check_circle),
  );

  testWidgets('idle shows nothing', (tester) async {
    await pumpList(tester, const UserSearchIdle());

    expect(find.byType(Text), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('loading shows a progress bar', (tester) async {
    await pumpList(tester, const UserSearchLoading());

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('no match says No one found.', (tester) async {
    await pumpList(tester, const UserSearchResults([]));

    expect(find.text('No one found.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a failed search says so', (tester) async {
    await pumpList(tester, const UserSearchFailed());

    expect(
      find.text(
        "Couldn't search. Check your connection and keep typing to try again.",
      ),
      findsOneWidget,
    );
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a row names the user, and gives the username under a profile '
      'name', (tester) async {
    await pumpList(tester, const UserSearchResults([_ana, _bo]));

    expect(find.byType(ListTile), findsNWidgets(2));
    // A profile name leads, with the username under it.
    expect(
      find.descendant(
        of: find.byKey(_rowKey('u_2')),
        matching: find.text('Ana B'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(_rowKey('u_2')),
        matching: find.text('ana'),
      ),
      findsOneWidget,
    );
    // Without one the username is the name, and is not said twice.
    expect(
      find.descendant(
        of: find.byKey(_rowKey('u_3')),
        matching: find.text('bo'),
      ),
      findsOneWidget,
    );
    expect(row(tester, 'u_3').subtitle, isNull);
  });

  testWidgets('a picked user is selected and checked', (tester) async {
    await pumpList(
      tester,
      const UserSearchResults([_ana, _bo]),
      picked: {'u_2'},
    );

    expect(row(tester, 'u_2').selected, isTrue);
    expect(checkIn('u_2'), findsOneWidget);
    expect(row(tester, 'u_3').selected, isFalse);
    expect(checkIn('u_3'), findsNothing);
  });

  testWidgets('more than one user can be picked at once', (tester) async {
    await pumpList(
      tester,
      const UserSearchResults([_ana, _bo]),
      picked: {'u_2', 'u_3'},
    );

    expect(row(tester, 'u_2').selected, isTrue);
    expect(row(tester, 'u_3').selected, isTrue);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
  });

  testWidgets('tapping a user calls onPick with them', (tester) async {
    final picks = <UserSummary>[];
    await pumpList(
      tester,
      const UserSearchResults([_ana, _bo]),
      onPick: picks.add,
    );

    await tester.tap(find.byKey(_rowKey('u_3')));
    await tester.pump();

    expect(picks, [_bo]);
  });

  testWidgets('with onPick null nothing can be tapped', (tester) async {
    await pumpList(
      tester,
      const UserSearchResults([_ana, _bo]),
      picked: {'u_2'},
      sending: true,
    );

    // The rows are still drawn, the pick among them still marked.
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(row(tester, 'u_2').selected, isTrue);
    expect(row(tester, 'u_2').onTap, isNull);
    expect(row(tester, 'u_3').onTap, isNull);
  });
}
