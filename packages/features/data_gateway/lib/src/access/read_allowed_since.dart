import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// Whether [access] has answered again since [sentUnder], the answer a
/// refused DataGateway read went out under, and the newer answer allows read
/// (#456).
///
/// A screen whose read is refused shows access-denied, and reads again when
/// a changed answer allows read. An answer that lands while the read is out
/// is no change by the time the refusal comes, and the ask the refusal sets
/// off finds that same answer, so nothing says it changed. The screen reads
/// again on this instead, once: the read that follows goes out under the
/// answer that is current, so a refusal of it is not one this answers.
bool readAllowedSince(CallerAccessRepository? access, CallerAccess? sentUnder) {
  final current = access?.current;
  return current != null &&
      current != sentUnder &&
      current.allows(ResourceType.dataGateway, AccessAction.read);
}
