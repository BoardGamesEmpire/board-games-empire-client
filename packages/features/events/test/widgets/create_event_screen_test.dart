import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_dates_section.dart';
import 'package:events/src/create/event_invitees_section.dart';
import 'package:events/src/create/event_rules_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import '../support/fake_user_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

/// What the repository hands back for a create: the local-only event, the
/// entry it queued, and the op as queued.
typedef _Created = ({
  Event event,
  String syncQueueId,
  CreateEventOperation operation,
});

/// The local-only event a create writes under [id].
Event _localEvent(String id) => Event(
  id: id,
  title: 'Game night',
  createdById: 'user-me',
  type: EventType.casualGathering,
  reach: Reach.friends,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  isDirty: true,
  isLocalOnly: true,
  createdAt: DateTime.utc(2026, 10, 26),
  updatedAt: DateTime.utc(2026, 10, 26),
);

Household _household(String id, String name) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

final _home = _household('h_1', 'Home');
final _club = _household('h_2', 'Club');

const _ana = UserSummary(id: 'u_1', username: 'ana', displayName: 'Ana B');
const _bo = UserSummary(id: 'u_2', username: 'bo', displayName: 'Bo C');

/// The server refusing the create for an invitee it has no account for, as
/// the sender parks it.
SyncParked _unknownInvitee(String userId) => SyncParked(
  EventCreateRefusedException(
    'Event create failed with status 404',
    statusCode: 404,
    apiMessage: 'User with ID $userId not found',
  ),
);

/// The server refusing the create without saying who, as its 403 does.
const _refusedQuietly = SyncParked(
  EventCreateRefusedException(
    'Event create failed with status 403',
    statusCode: 403,
  ),
);

const _titleRequired = 'Give the event a title.';
const _linkInvalid = 'Enter a full link, starting with https://';
const _syncedCopy = 'Event created.';
const _queuedCopy = "Event saved. It'll be sent when you're back online.";

/// The heading of every banner a create that failed shows: some of their
/// messages give only a cause.
const _failedTitle = "Couldn't create the event";
const _refusedCopy =
    "Someone you invited may not accept invites from you. Change who's "
    'invited and try again.';
const _refusedHouseholdCopy =
    'You may no longer be allowed to create events in this household. Pick '
    'another household, or none, and try again.';
const _refusedOtherCopy =
    "The server didn't accept it as it stands. Check the details and try "
    'again.';
const _errorCopy = "It couldn't be saved on this device. Try again.";

/// Pins the event create screen (#499) end to end over a mocked repository
/// and sender: the draft a filled-in form sends, the households it may
/// join, and what each outcome of the send shows.
///
/// Where the created event is shown is not this seam's business: the
/// screen hands its id to `onCreated`, and the shell turns that into a
/// route change.
void main() {
  // Local, as the pickers give it: Monday 26 October 2026, 6 PM.
  final now = DateTime(2026, 10, 26, 18);

  late _MockEventRepository repo;
  late _MockSyncOperationSender sender;
  late FakeUserRemote users;

  /// Every create the repository answered, in order.
  late List<_Created> creates;

  /// The ids handed to `onCreated`, in order.
  late List<String> created;

  /// Answers a create as the repository does: `ev_local_1` under `q1`, then
  /// `ev_local_2` under `q2`.
  _Created answerCreate(Invocation invocation) {
    final n = creates.length + 1;
    final result = (
      event: _localEvent('ev_local_$n'),
      syncQueueId: 'q$n',
      operation: CreateEventOperation(
        localId: 'ev_local_$n',
        draft: invocation.positionalArguments.single as EventDraft,
      ),
    );
    creates.add(result);
    return result;
  }

  /// The drafts the repository was asked to create, in order.
  List<EventDraft> sent() => [for (final c in creates) c.operation.draft];

  setUpAll(() {
    registerFallbackValue(const EventDraft(title: 'x'));
    registerFallbackValue(
      const CreateEventOperation(
        localId: 'x',
        draft: EventDraft(title: 'x'),
      ),
    );
  });

  setUp(() {
    repo = _MockEventRepository();
    sender = _MockSyncOperationSender();
    users = FakeUserRemote()..onSearchUsers = (_) async => pageOf([_ana, _bo]);
    creates = [];
    created = [];

    when(() => repo.create(any()))
        .thenAnswer((invocation) async => answerCreate(invocation));
    when(() => repo.discardQueuedOp(any())).thenAnswer((_) async => true);
    // The common case: the sender delivers it, and the cache holds the
    // event under the server's id.
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered(eventId: 'ev_server'));
  });

  /// Answers each send with the next of [deliveries], in order.
  void stubDeliveries(List<SyncDelivery> deliveries) {
    final answers = [...deliveries];
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => answers.removeAt(0));
  }

  /// The screen, pushed above a page of its own as the shell pushes it, so
  /// that a screen leaving on its own would show.
  Widget harness({
    Stream<List<Household>>? households,
    String? householdId,
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: [
      ...EventsLocalizations.localizationsDelegates,
      UserSearchLocalizations.delegate,
    ],
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => CreateEventScreen(
                  repository: repo,
                  sender: sender,
                  users: users,
                  households: households,
                  householdId: householdId,
                  now: () => now,
                  onCreated: (_, eventId) => created.add(eventId),
                ),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    Stream<List<Household>>? households,
    String? householdId,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(
      harness(
        households: households,
        householdId: householdId,
        textScaler: textScaler,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enterText(WidgetTester tester, Key field, String text) async {
    await reveal(tester, find.byKey(field));
    await tester.enterText(find.byKey(field), text);
    await tester.pump();
  }

  /// Picks the first date's start, taking what each picker opens on: today
  /// at six.
  Future<void> pickStart(WidgetTester tester) async {
    final field = find.byKey(EventCreateDatesSection.startKey(0));
    await reveal(tester, field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  /// Fills in what a create needs: a title and when it starts.
  Future<void> fill(WidgetTester tester, {String title = 'Game night'}) async {
    await enterText(tester, CreateEventScreen.titleKey, title);
    await pickStart(tester);
  }

  /// Finds [user] through the search and picks them.
  Future<void> invite(WidgetTester tester, UserSummary user) async {
    await enterText(tester, EventInviteesSection.searchKey, user.username);
    // The search waits out its pause before it asks.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final row = find.byKey(EventInviteesSection.resultKey(user.id));
    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Opens the menu [field] and picks [option] from it.
  Future<void> choose(WidgetTester tester, Key field, String option) async {
    await reveal(tester, find.byKey(field));
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    // The menu's copy, above the field's own.
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.byKey(CreateEventScreen.submitKey);
    await reveal(tester, button);
    await tester.tap(button);
    await tester.pump();
  }

  /// Lets a create that succeeded land. Not a settle: the button spins
  /// until the route closes, and this harness's `onCreated` leaves it open.
  Future<void> landed(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Finder inSnackBar(String copy) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

  Finder inBanner(Key banner, String copy) =>
      find.descendant(of: find.byKey(banner), matching: find.text(copy));

  /// [name] as what the household picker shows.
  Finder pickerShows(String name) => find.descendant(
    of: find.byKey(CreateEventScreen.householdKey),
    matching: find.text(name),
  );

  DropdownButton<T> menu<T>(WidgetTester tester) =>
      tester.widget<DropdownButton<T>>(find.byType(DropdownButton<T>));

  TextField textField(WidgetTester tester, Key field) =>
      tester.widget<TextField>(
        find.descendant(
          of: find.byKey(field),
          matching: find.byType(TextField),
        ),
      );

  testWidgets('a blank title is not sent', (tester) async {
    await open(tester);
    await fill(tester, title: '   ');
    // Typing further down, so the title isn't where the user is.
    await enterText(tester, CreateEventScreen.locationKey, "Ana's place");

    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text(_titleRequired), findsOneWidget);
    verifyNever(() => repo.create(any()));
    // The refused submit goes back to it.
    expect(
      textField(tester, CreateEventScreen.titleKey).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets("a link that isn't a full http(s) URL is refused", (
    tester,
  ) async {
    await open(tester);
    await fill(tester);

    for (final link in [
      'example.com',
      'ftp://x.org',
      // The server's own check refuses these.
      'https://localhost',
      'https://my_site.com',
    ]) {
      await enterText(tester, CreateEventScreen.urlKey, link);
      await submit(tester);
      await tester.pumpAndSettle();

      expect(find.text(_linkInvalid), findsOneWidget, reason: link);
    }
    verifyNever(() => repo.create(any()));
  });

  testWidgets('a full link is sent as typed, trimmed', (tester) async {
    await open(tester);
    await fill(tester);
    await enterText(
      tester,
      CreateEventScreen.urlKey,
      '  https://example.com/night ',
    );

    await submit(tester);
    await landed(tester);

    expect(sent().single.url, 'https://example.com/night');
  });

  testWidgets('a valid form sends the draft it shows', (tester) async {
    await open(tester, households: Stream.value([_home, _club]));
    await enterText(tester, CreateEventScreen.titleKey, '  Game night ');
    await choose(tester, CreateEventScreen.householdKey, 'Club');
    await pickStart(tester);
    await invite(tester, _bo);

    await submit(tester);
    await landed(tester);

    final draft = sent().single;
    expect(
      draft,
      EventDraft(
        title: 'Game night',
        householdId: 'h_2',
        occurrences: [EventOccurrenceDraft(startDate: now.toUtc())],
        inviteUserIds: const ['u_2'],
      ),
    );
    expect(draft.occurrences.single.startDate!.isUtc, isTrue);
    // The rules are untouched, so the server's apply.
    expect(draft.policy, isNull);
  });

  testWidgets('type and who can see it start as the server has them, and '
      'offer only what it knows', (tester) async {
    await open(tester);

    // Untouched, each reads as the server's default, and is left out.
    expect(
      find.descendant(
        of: find.byKey(CreateEventScreen.typeKey),
        matching: find.text('Casual gathering'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(CreateEventScreen.reachKey),
        matching: find.text('Friends'),
      ),
      findsOneWidget,
    );
    expect(menu<EventType>(tester).value, isNull);
    expect(menu<Reach>(tester).value, isNull);
    expect(menu<EventType>(tester).items!.map((item) => item.value), [
      for (final type in EventType.values)
        if (type != EventType.unknown) type,
    ]);
    // From the narrowest to the widest.
    expect(menu<Reach>(tester).items!.map((item) => item.value), [
      Reach.private,
      Reach.friends,
      Reach.friendsOfFriends,
      Reach.public,
    ]);

    await choose(tester, CreateEventScreen.typeKey, 'Strategy night');
    await choose(tester, CreateEventScreen.reachKey, 'Public');
    await fill(tester);
    await submit(tester);
    await landed(tester);

    expect(
      (sent().single.type, sent().single.reach),
      (EventType.strategyNight, Reach.public),
    );
  });

  group('the household', () {
    testWidgets('a prefill the picker offers is chosen', (tester) async {
      await open(
        tester,
        households: Stream.value([_home, _club]),
        householdId: 'h_2',
      );

      expect(pickerShows('Club'), findsOneWidget);
      await fill(tester);
      await submit(tester);
      await landed(tester);

      expect(sent().single.householdId, 'h_2');
    });

    testWidgets('a prefill waits for a list that offers it', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      // A household the user's membership in isn't read yet, as on a link
      // opened before the first hydrate.
      await open(tester, households: households.stream, householdId: 'h_lodge');
      households.add([_home]);
      await tester.pumpAndSettle();
      expect(pickerShows('No household'), findsOneWidget);

      households.add([_home, _household('h_lodge', 'Lodge')]);
      await tester.pumpAndSettle();
      expect(pickerShows('Lodge'), findsOneWidget);

      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, 'h_lodge');
    });

    testWidgets("a prefill doesn't replace the user's own pick", (
      tester,
    ) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_lodge');
      households.add([_home, _club]);
      await tester.pumpAndSettle();
      await choose(tester, CreateEventScreen.householdKey, 'Club');
      await choose(tester, CreateEventScreen.householdKey, 'No household');

      households.add([_home, _club, _household('h_lodge', 'Lodge')]);
      await tester.pumpAndSettle();
      expect(pickerShows('No household'), findsOneWidget);

      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets("a prefill doesn't change the household a refused create "
        'was sent in', (tester) async {
      stubDeliveries([_refusedQuietly]);
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_lodge');
      households.add([_home]);
      await tester.pumpAndSettle();
      await fill(tester);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

      households.add([_home, _household('h_lodge', 'Lodge')]);
      await tester.pumpAndSettle();

      expect(pickerShows('No household'), findsOneWidget);
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);
    });

    testWidgets('a household that leaves the list is unpicked', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream);
      households.add([_home, _club]);
      await tester.pumpAndSettle();
      await choose(tester, CreateEventScreen.householdKey, 'Club');
      expect(pickerShows('Club'), findsOneWidget);

      // A later list drops it, as one read after the user's role in it
      // changed elsewhere would.
      households.add([_home]);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(pickerShows('No household'), findsOneWidget);
      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets('a pick made in a menu opened before the list dropped that '
        'household is not sent', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream);
      households.add([_home, _club]);
      await tester.pumpAndSettle();
      await fill(tester);
      final picker = find.byKey(CreateEventScreen.householdKey);
      await reveal(tester, picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(find.text('Club'), findsWidgets);

      // A later list drops Club while the menu is open.
      households.add([_home]);
      await tester.pumpAndSettle();

      // The menu went with the list it was opened on, so Club is nowhere
      // left to pick.
      expect(tester.takeException(), isNull);
      expect(find.text('Club'), findsNothing);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets('a submit before the households answer sends no household', (
      tester,
    ) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      await open(tester, households: households.stream, householdId: 'h_1');

      // Drawn, with nothing to pick until they answer.
      expect(pickerShows('No household'), findsOneWidget);
      expect(menu<String?>(tester).onChanged, isNull);

      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });

    testWidgets('without households there is no picker, and a prefill is '
        'dropped', (tester) async {
      await open(tester, householdId: 'h_1');

      expect(find.byKey(CreateEventScreen.householdKey), findsNothing);
      await fill(tester);
      await submit(tester);
      await landed(tester);
      expect(sent().single.householdId, isNull);
    });
  });

  group('the outcome', () {
    testWidgets('a delivered create says so and calls onCreated with the '
        'server id', (tester) async {
      await open(tester);
      await fill(tester);

      await submit(tester);
      await landed(tester);

      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(created, ['ev_server']);
      verify(() => sender.deliver('q1', any())).called(1);
      // Where the event is shown is the caller's: the screen doesn't leave
      // on its own.
      expect(find.byType(CreateEventScreen), findsOneWidget);
    });

    testWidgets('a queued create says so and calls onCreated with the local '
        'id', (tester) async {
      stubDeliveries([
        SyncFailed(SyncFailure.unreachable, Exception('offline')),
      ]);
      await open(tester);
      await fill(tester);

      await submit(tester);
      await landed(tester);

      expect(inSnackBar(_queuedCopy), findsOneWidget);
      expect(inSnackBar(_syncedCopy), findsNothing);
      expect(created, ['ev_local_1']);
    });

    testWidgets('a refusal naming an invitee stays on the form and names '
        'them', (tester) async {
      stubDeliveries([_unknownInvitee('u_1')]);
      await open(tester);
      await fill(tester);
      await invite(tester, _ana);
      await invite(tester, _bo);

      await submit(tester);
      await tester.pumpAndSettle();

      // Under a heading that says what failed: the message gives only why.
      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(
        inBanner(
          CreateEventScreen.refusedKey,
          "Ana B can't be invited. Take them off and try again.",
        ),
        findsOneWidget,
      );
      expect(created, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      // Still the form, as it was sent.
      expect(
        find.byKey(EventInviteesSection.inviteeKey('u_1')),
        findsOneWidget,
      );
      expect(textField(tester, CreateEventScreen.titleKey).readOnly, isFalse);
    });

    testWidgets('a refusal naming no one stays on the form', (tester) async {
      stubDeliveries([_refusedQuietly]);
      await open(tester, households: Stream.value([_home]));
      await choose(tester, CreateEventScreen.householdKey, 'Home');
      await fill(tester);
      await invite(tester, _ana);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(inBanner(CreateEventScreen.refusedKey, _refusedCopy), findsOne);
      expect(created, isEmpty);

      // Any edit takes it down: it is about the form as it was sent.
      await enterText(tester, CreateEventScreen.titleKey, 'Game night 2');
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsNothing);
    });

    testWidgets('a refusal with no one invited points at the household', (
      tester,
    ) async {
      stubDeliveries([_refusedQuietly]);
      await open(tester, households: Stream.value([_home]), householdId: 'h_1');
      await fill(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedHouseholdCopy),
        findsOneWidget,
      );
      expect(created, isEmpty);
    });

    testWidgets("a refusal with no one invited and no household blames "
        'neither', (tester) async {
      stubDeliveries([_refusedQuietly]);
      await open(tester, households: Stream.value([_home]));
      await fill(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.refusedKey, _failedTitle), findsOne);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedOtherCopy),
        findsOneWidget,
      );
      expect(created, isEmpty);
    });

    testWidgets('taking the invitee off and creating again sends a new '
        'create', (tester) async {
      stubDeliveries([
        _unknownInvitee('u_1'),
        const SyncDelivered(eventId: 'ev_server'),
      ]);
      await open(tester);
      await fill(tester);
      await invite(tester, _ana);
      await invite(tester, _bo);
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

      final remove = find.byTooltip('Remove Ana B');
      await reveal(tester, remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.refusedKey), findsNothing);

      await submit(tester);
      await landed(tester);

      // The refused create goes, then the form as it stands now is created
      // afresh.
      verifyInOrder([
        () => repo.create(any()),
        () => repo.discardQueuedOp('q1'),
        () => repo.create(any()),
      ]);
      expect(sent().map((draft) => draft.inviteUserIds), [
        ['u_1', 'u_2'],
        ['u_2'],
      ]);
      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(created, ['ev_server']);
    });

    testWidgets('a create that fails here says so above the submit', (
      tester,
    ) async {
      when(() => repo.create(any())).thenThrow(StateError('database locked'));
      await open(tester);
      await fill(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(inBanner(CreateEventScreen.errorKey, _failedTitle), findsOne);
      expect(inBanner(CreateEventScreen.errorKey, _errorCopy), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(created, isEmpty);
      final banner = tester.getRect(find.byKey(CreateEventScreen.errorKey));
      final button = tester.getRect(find.byKey(CreateEventScreen.submitKey));
      expect(banner.bottom, lessThan(button.top));

      await enterText(tester, CreateEventScreen.titleKey, 'Game night 2');
      await tester.pumpAndSettle();
      expect(find.byKey(CreateEventScreen.errorKey), findsNothing);
    });

    testWidgets('nothing takes an edit while a create is on its way', (
      tester,
    ) async {
      final delivery = Completer<SyncDelivery>();
      when(() => sender.deliver(any(), any()))
          .thenAnswer((_) => delivery.future);
      await open(tester, households: Stream.value([_home]));
      await fill(tester);

      await submit(tester);
      await tester.pump();

      expect(find.text('Creating…'), findsOneWidget);
      for (final field in [
        CreateEventScreen.titleKey,
        CreateEventScreen.descriptionKey,
        CreateEventScreen.locationKey,
        CreateEventScreen.urlKey,
      ]) {
        expect(textField(tester, field).readOnly, isTrue, reason: '$field');
      }
      expect(menu<String?>(tester).onChanged, isNull);
      expect(menu<EventType>(tester).onChanged, isNull);
      expect(menu<Reach>(tester).onChanged, isNull);
      // And every section below the basics.
      expect(
        tester
            .widget<SegmentedButton<EventSchedulingMode>>(
              find.byKey(EventCreateDatesSection.modeKey),
            )
            .onSelectionChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(EventInviteesSection.searchKey))
            .readOnly,
        isTrue,
      );

      delivery.complete(const SyncDelivered(eventId: 'ev_server'));
      await landed(tester);
      expect(created, ['ev_server']);
      // Nor once it is done, with the form about to close.
      expect(textField(tester, CreateEventScreen.titleKey).readOnly, isTrue);
      expect(find.text('Creating…'), findsOneWidget);
    });

    testWidgets('a refusal is about the household it was sent in, though the '
        'list dropped it since', (tester) async {
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      final delivery = Completer<SyncDelivery>();
      when(() => sender.deliver(any(), any()))
          .thenAnswer((_) => delivery.future);
      await open(tester, households: households.stream, householdId: 'h_1');
      households.add([_home]);
      await tester.pumpAndSettle();
      await fill(tester);
      await submit(tester);

      // The user's role in it changed elsewhere, so the server refuses the
      // create, and a list read since drops the household while the create
      // is on its way.
      households.add(const []);
      await tester.pump();
      delivery.complete(_refusedQuietly);
      await tester.pumpAndSettle();

      expect(pickerShows('No household'), findsOneWidget);
      expect(
        inBanner(CreateEventScreen.refusedKey, _refusedHouseholdCopy),
        findsOneWidget,
      );
    });
  });

  testWidgets('the form fits at 320dp wide at 2.0 text scale', (tester) async {
    useViewSize(tester, const Size(320, 568));
    stubDeliveries([_unknownInvitee('u_1')]);
    await open(
      tester,
      households: Stream.value([_home, _club]),
      householdId: 'h_2',
      textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
    );

    // Every error the basics and the dates can show, as after a refused
    // submit.
    await submit(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(_titleRequired), findsOneWidget);

    // Each menu's choice lays out whole: a dense menu would squeeze it into
    // one line's height, which throws nothing.
    for (final (field, choice) in [
      (CreateEventScreen.householdKey, 'Club'),
      (CreateEventScreen.typeKey, 'Casual gathering'),
      (CreateEventScreen.reachKey, 'Friends'),
    ]) {
      await reveal(tester, find.byKey(field));
      final text = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byKey(field), matching: find.text(choice)),
      );
      expect(
        text.size.height,
        greaterThanOrEqualTo(text.getMaxIntrinsicHeight(text.size.width)),
        reason: choice,
      );
    }

    // A refusal, with the rules open below it.
    await fill(tester);
    await invite(tester, _ana);
    await submit(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(CreateEventScreen.refusedKey), findsOneWidget);

    await reveal(tester, find.byKey(EventRulesSection.tileKey));
    await tester.tap(find.text('Advanced: rules'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
