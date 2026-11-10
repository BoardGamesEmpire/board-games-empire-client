import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:data_gateway/src/bloc/language_tag_search_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens the language tag picker (#457) and answers the tag the admin chose,
/// or null when the dialog is dismissed by Cancel, by a tap outside it or by
/// Back.
///
/// [value] is the DataGateway's own value for a language, such as `Czech`,
/// which the title names. The picker only chooses: the caller links the tag.
///
/// The [LanguageTagSearchCubit] is made inside the dialog's route, so it
/// closes with the route. A read still out when the dialog closes is dropped.
Future<LanguageTagRef?> showLanguageTagPicker(
  BuildContext context, {
  required DataGatewayRemoteDataSource remote,
  required String value,
}) => showDialog<LanguageTagRef>(
  context: context,
  builder: (_) => BlocProvider<LanguageTagSearchCubit>(
    create: (_) => LanguageTagSearchCubit(remote: remote),
    child: LanguageTagPickerDialog(value: value),
  ),
);

/// The dialog an admin picks a language tag in (#457): a field that narrows
/// the server's languages by name, and a row for each of their tags.
///
/// It answers the chosen [LanguageTagRef] through its route. What it shows
/// comes from the [LanguageTagSearchCubit] above it: [showLanguageTagPicker]
/// provides one.
///
/// ## Layout
///
/// The title, the field and the rows scroll together, and Cancel stays put
/// below them. At 200% text on a phone with the keyboard up, a title that
/// names a long value takes most of the room by itself, so no part of the
/// dialog can keep a place of its own: pinning the field above a list that
/// scrolls would leave the list none. The rows are a column, not a list, so
/// the dialog can ask them how wide it needs to be.
///
/// The title is not shortened: the value is what the admin is choosing a
/// language for, and a low-vision reader should not lose the end of it. A
/// screen reader hears it whole either way.
///
/// ## Reading it
///
/// - The field has focus when the dialog opens, and its label is its name.
/// - A row is one button, naming the language and then its tag.
/// - The first page loading, a next page loading, a failure and an empty
///   result are each a live region, so assistive tech says them as they
///   appear.
/// - Show more stays in place and stays enabled while its page loads, and
///   the cubit drops a press made meanwhile. A disabled button gives up
///   keyboard focus (#607), and a button that went mid-press would take the
///   focus with it. After a failed next page the same button reads Try again,
///   so one control retries.
class LanguageTagPickerDialog extends StatelessWidget {
  const LanguageTagPickerDialog({required this.value, super.key});

  static const Key searchKey = Key('language_tag_picker.search');
  static const Key loadingKey = Key('language_tag_picker.loading');
  static const Key emptyKey = Key('language_tag_picker.empty');
  static const Key errorKey = Key('language_tag_picker.error');

  /// The Try again button under a first page that failed. A failed next page
  /// retries through [moreKey].
  static const Key retryKey = Key('language_tag_picker.retry');
  static const Key moreKey = Key('language_tag_picker.more');

  /// The end of the list, which holds [moreKey] and the progress and failure
  /// of the next page. There while the server has more.
  static const Key footerKey = Key('language_tag_picker.footer');
  static const Key cancelKey = Key('language_tag_picker.cancel');

  /// Per-row key: `language_tag_picker.row_<id>`, with the tag's id.
  static Key rowKey(String id) => Key('language_tag_picker.row_$id');

  /// The DataGateway's own value, which the title names.
  final String value;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final title = l10n.dataGatewayLanguagePickerTitle(value);

    return AlertDialog(
      // Title and content scroll together; the actions stay below.
      scrollable: true,
      // What a screen reader says as the dialog opens. Left out, Android
      // says "Alert", and the title is not read until the reader finds it.
      semanticLabel: title,
      title: Text(title),
      // Without a width of its own the dialog sizes itself to what its
      // content says it needs, which a column of rows answers as the width of
      // the widest of them.
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: searchKey,
              autofocus: true,
              // Names of languages, which a keyboard would correct into words.
              autocorrect: false,
              textInputAction: TextInputAction.search,
              onChanged: (text) =>
                  context.read<LanguageTagSearchCubit>().search(text),
              decoration: InputDecoration(
                labelText: l10n.dataGatewayLanguagePickerSearchLabel,
                // The server matches a language's name only: a tag, or a
                // place such as Brazil, finds nothing (#457).
                helperText: l10n.dataGatewayLanguagePickerSearchHelper,
                prefixIcon: const Icon(Icons.search),
              ),
            ),
            const BgeGap.md(),
            const _Results(),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dataGatewayCancel),
        ),
      ],
    );
  }
}

/// What the cubit has read: the first page loading or failed, the rows, and
/// the end of the list.
///
/// Each control is keyed, so it keeps its place, and its keyboard focus, as
/// the parts around it come and go.
class _Results extends StatelessWidget {
  const _Results();

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return BlocBuilder<LanguageTagSearchCubit, LanguageTagSearchState>(
      builder: (context, state) {
        // Nothing to show, and nothing more to wait for. A page of languages
        // with no tags has no rows and more behind it: that is not this.
        final empty =
            state.tags.isEmpty &&
            !state.hasMore &&
            !state.loading &&
            !state.loadingMore &&
            !state.failed &&
            !state.moreFailed;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.loading)
              const _Loading(key: LanguageTagPickerDialog.loadingKey),
            if (state.failed) ...[
              const _Failure(key: LanguageTagPickerDialog.errorKey),
              const BgeGap.sm(),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  key: LanguageTagPickerDialog.retryKey,
                  onPressed: () =>
                      context.read<LanguageTagSearchCubit>().retry(),
                  child: Text(l10n.dataGatewayRetry),
                ),
              ),
            ],
            if (empty)
              BgeEmptyState(
                key: LanguageTagPickerDialog.emptyKey,
                title: l10n.dataGatewayLanguagePickerEmpty,
              ),
            for (final tag in state.tags)
              _TagRow(key: LanguageTagPickerDialog.rowKey(tag.id), tag: tag),
            if (state.hasMore)
              _MoreFooter(key: LanguageTagPickerDialog.footerKey, state: state),
          ],
        );
      },
    );
  }
}

/// One language tag: its name, and under it the BCP 47 tag, as one button.
///
/// Nothing is added to the tile's own semantics. A `ListTile` with an `onTap`
/// says it is a button, and its name and tag read as one node with the tap.
/// A `Semantics(button: true)` around it would add a second, unlabelled
/// button to every row.
class _TagRow extends StatelessWidget {
  const _TagRow({required this.tag, super.key});

  final LanguageTagRef tag;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: () => Navigator.of(context).pop(tag),
    title: Text(tag.name),
    subtitle: Text(tag.tag),
  );
}

/// The end of the list: the next page's button, its progress, or its failure.
class _MoreFooter extends StatelessWidget {
  const _MoreFooter({required this.state, super.key});

  final LanguageTagSearchState state;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return Padding(
      padding: EdgeInsets.only(top: BgeTokens.of(context).spaceSm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.moreFailed) ...[
            const _Failure(key: LanguageTagPickerDialog.errorKey),
            const BgeGap.sm(),
          ],
          if (state.loadingMore) ...[
            const _Loading(key: LanguageTagPickerDialog.loadingKey),
            const BgeGap.sm(),
          ],
          // Enabled through its own page: see the dialog's doc.
          OutlinedButton(
            key: LanguageTagPickerDialog.moreKey,
            onPressed: () => context.read<LanguageTagSearchCubit>().more(),
            child: Text(
              state.moreFailed
                  ? l10n.dataGatewayRetry
                  : l10n.dataGatewayLanguagePickerMore,
            ),
          ),
        ],
      ),
    );
  }
}

/// A spinner that is said, not only drawn: [BgeLoadingState], labelled with
/// what is loading.
class _Loading extends StatelessWidget {
  const _Loading({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: BgeLoadingState(
      label: DataGatewayLocalizations.of(context)
          .dataGatewayLanguagePickerLoading,
    ),
  );
}

/// That reading languages failed, as an icon and words and not color alone,
/// in a live region.
class _Failure extends StatelessWidget {
  const _Failure({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;

    // The merge outside and the live region inside, so the flag and the words
    // land on one node.
    return MergeSemantics(
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: color),
            const BgeGap.sm(axis: Axis.horizontal),
            Expanded(
              child: Text(
                DataGatewayLocalizations.of(context)
                    .dataGatewayLanguagePickerFailed,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
