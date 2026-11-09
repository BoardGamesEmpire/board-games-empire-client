import 'package:flutter/widgets.dart';
import 'package:models/domain.dart';

/// One section of the admin dashboard (#684): an entry that opens a
/// section's own screens, such as the DataGateway list.
///
/// Presentation-agnostic, as `HomeMenuEntry` is: the composition layer
/// resolves each feature's strings and route and hands the finished section
/// in, so the dashboard learns no feature's internals.
@immutable
final class AdminSection {
  const AdminSection({
    required this.id,
    required this.icon,
    required this.title,
    required this.summary,
    required this.resourceType,
    required this.onOpen,
  });

  /// Stable identifier, unique among the sections; it keys the entry.
  final String id;

  /// The entry's leading icon. Says nothing to a screen reader: the title
  /// names the section.
  final IconData icon;

  /// The section's name. Already localized.
  final String title;

  /// One line saying what the section holds. Already localized.
  final String summary;

  /// The resource type whose `read` decides whether the section shows. See
  /// [visibleAdminSections].
  final ResourceType resourceType;

  /// Opens the section, with the context of the entry that was pressed.
  final void Function(BuildContext context) onOpen;
}

/// The [sections] that [access] shows, in the order given.
///
/// A section shows when the caller may read every resource of its type: its
/// `read` extent is [AccessExtent.all] (#274). [AccessExtent.some] is what a
/// plain member has, of the households they belong to, so it is not enough
/// for a section that covers the whole server. Nothing shows while [access]
/// is unknown.
List<AdminSection> visibleAdminSections(
  CallerAccess access,
  Iterable<AdminSection> sections,
) => [
  for (final section in sections)
    if (access.extentOf(section.resourceType, AccessAction.read) ==
        AccessExtent.all)
      section,
];
