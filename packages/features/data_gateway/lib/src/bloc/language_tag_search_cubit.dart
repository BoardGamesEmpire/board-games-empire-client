import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What the language tag picker shows (#457): the language tags the server
/// listed for the name searched, a page at a time.
final class LanguageTagSearchState extends Equatable {
  const LanguageTagSearchState({
    this.tags = const [],
    this.loading = true,
    this.loadingMore = false,
    this.failed = false,
    this.moreFailed = false,
    this.hasMore = false,
  });

  /// The tags read so far, in the server's order: languages alphabetical by
  /// name, and each language's tags by tag.
  ///
  /// Empty while [loading] and after a read [failed]. It can also be empty
  /// with [hasMore] true, which is not an empty result: see [hasMore].
  final List<LanguageTagRef> tags;

  /// The first page is being read, with no [tags] to show meanwhile.
  final bool loading;

  /// The next page is being read. The [tags] shown are still right.
  final bool loadingMore;

  /// The first page could not be read. Retryable.
  final bool failed;

  /// The last try at the next page failed. The [tags] shown are still right,
  /// and trying again asks for the same page.
  final bool moreFailed;

  /// Whether the server has more past the pages read.
  ///
  /// The server pages languages, and a language with no tags adds no tag. So
  /// a page can bring no [tags] and still have more behind it, and an empty
  /// list with this true means keep reading, not "nothing matches".
  final bool hasMore;

  @override
  List<Object?> get props => [
    tags,
    loading,
    loadingMore,
    failed,
    moreFailed,
    hasMore,
  ];
}

/// Drives the search in the language tag picker (#457): the server's language
/// tags for a name an admin types, a page at a time.
///
/// Nothing is cached (#41). The first page, for no name, is read as the cubit
/// is made, with no debounce: the picker opens onto something to choose from.
///
/// ## Searching
///
/// [search] waits for the user to stop typing, so a name typed over a second
/// sends one read rather than one per key. Only the last name typed in the
/// wait is sent. The name is trimmed, and a name that is the same as the one
/// last asked for sends nothing: not when typed again, and not when typed
/// over another and back within the wait. Changing the name starts the list
/// over from the spinner, since the tags shown belong to the old one. A read
/// that fails stays failed until [retry], even for the same name typed again.
///
/// ## Pages
///
/// A read asks for the first page. [more] asks for the page after the one the
/// last answer was, by that answer's own paging. It never works the page out
/// from how many tags are shown: the server pages languages, not tags, and a
/// language can have none, one or many. A page of languages with no tags is a
/// page with no items, and it can have more behind it, so an empty page is
/// not the end. Only the server's word is.
///
/// More does nothing while the first page is loading, while another More is
/// out, after the first page failed, or once the server has said there is no
/// more. A More that fails keeps the tags and says so, and the next one asks
/// for the same page again. A tag the next page repeats, as it can when the
/// server's list shifts between two reads, is shown once.
///
/// ## Reads overlap
///
/// Of two reads of a first page, the one asked for last wins, whichever
/// answers first. More shares that number without moving it, so a search or a
/// retry that starts while More is out drops More's answer when it lands, and
/// More stops showing at once: a page of the old name's tags would not belong
/// under the new name.
///
/// ## Closing
///
/// The picker closes with its dialog, and the dialog can close with a read in
/// flight or a search waiting out its debounce. Closing drops the waiting
/// search. A read that lands later is dropped too: a cubit that emits after
/// it is closed throws, so every answer is checked for that before it is
/// shown. A closed cubit ignores [more], [retry] and [search].
class LanguageTagSearchCubit extends Cubit<LanguageTagSearchState> {
  LanguageTagSearchCubit({
    required this._remote,
    this._debounce = const Duration(milliseconds: 300),
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.data_gateway.language_tags'),
       super(const LanguageTagSearchState()) {
    unawaited(_readFirstPage(''));
  }

  final DataGatewayRemoteDataSource _remote;
  final Duration _debounce;
  final BgeLogger _logger;

  /// The name the latest read of a first page was asked for, trimmed. Empty
  /// for none.
  String _asked = '';

  /// The page the last answer was, by its own paging. More asks for the one
  /// after it.
  int _page = 0;

  /// Which read of a first page is the latest. An older one that answers
  /// late is dropped, and so is a More that was asked for before it.
  int _readSequence = 0;

  /// The search waiting out its debounce, if there is one.
  Timer? _waiting;

  /// Searches for [name], once the user has stopped typing for the debounce.
  void search(String name) {
    final wanted = name.trim();
    _waiting?.cancel();
    _waiting = null;
    if (wanted == _asked) return;
    _waiting = Timer(_debounce, () {
      _waiting = null;
      if (isClosed) return;
      unawaited(_readFirstPage(wanted));
    });
  }

  /// Reads the next page and adds its tags to the ones shown.
  void more() {
    final shown = state;
    if (isClosed ||
        shown.loading ||
        shown.loadingMore ||
        shown.failed ||
        !shown.hasMore) {
      return;
    }
    unawaited(_readNextPage(shown));
  }

  /// Reads the first page of the current name again, in place of whatever is
  /// shown.
  void retry() {
    if (isClosed) return;
    unawaited(_readFirstPage(_asked));
  }

  Future<void> _readFirstPage(String name) async {
    final read = ++_readSequence;
    _asked = name;
    _page = 0;
    emit(const LanguageTagSearchState());
    final PaginatedResult<LanguageTagRef> result;
    try {
      result = await _remote.fetchLanguageTags(
        name: name.isEmpty ? null : name,
      );
    } on Object catch (error, stackTrace) {
      if (_dropped(read)) return;
      _logger.warn(
        'Language tag read failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const LanguageTagSearchState(loading: false, failed: true));
      return;
    }
    if (_dropped(read)) return;
    _page = result.meta.page;
    emit(
      LanguageTagSearchState(
        tags: result.items,
        loading: false,
        hasMore: result.meta.hasMore,
      ),
    );
  }

  Future<void> _readNextPage(LanguageTagSearchState shown) async {
    // Shares the read sequence without moving it, so a search or a retry
    // asked for while this is out drops its answer.
    final read = _readSequence;
    final page = _page + 1;
    emit(
      LanguageTagSearchState(
        tags: shown.tags,
        loading: false,
        loadingMore: true,
        hasMore: true,
      ),
    );
    final PaginatedResult<LanguageTagRef> result;
    try {
      result = await _remote.fetchLanguageTags(
        name: _asked.isEmpty ? null : _asked,
        page: page,
      );
    } on Object catch (error, stackTrace) {
      if (_dropped(read)) return;
      _logger.warn(
        'Language tag page $page failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(
        LanguageTagSearchState(
          tags: shown.tags,
          loading: false,
          moreFailed: true,
          hasMore: true,
        ),
      );
      return;
    }
    if (_dropped(read)) return;
    // Nothing else changes the tags while this is out: a search or a retry
    // drops it first.
    final known = {for (final tag in shown.tags) tag.id};
    _page = result.meta.page;
    emit(
      LanguageTagSearchState(
        tags: [
          ...shown.tags,
          for (final tag in result.items)
            if (known.add(tag.id)) tag,
        ],
        loading: false,
        hasMore: result.meta.hasMore,
      ),
    );
  }

  /// Whether the answer to read number [read] is no longer wanted: a newer
  /// read was asked for, or the cubit closed while this one was out.
  bool _dropped(int read) => read != _readSequence || isClosed;

  @override
  Future<void> close() {
    _waiting?.cancel();
    _waiting = null;
    return super.close();
  }
}
