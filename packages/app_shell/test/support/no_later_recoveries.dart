import 'package:models/domain.dart';

/// For the `MockCubit` stand-ins of `AppBootstrapCubit`, whose unstubbed
/// getters return null: the recovery notice listens to this one from the
/// first build, and no rebuild after boot happens in these tests.
mixin NoLaterRecoveries {
  Stream<List<ServerConfig>> get laterRecoveries => const Stream.empty();
}
