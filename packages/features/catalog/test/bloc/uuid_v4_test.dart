import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/bloc/uuid_v4.dart';

/// A [Random] that answers every byte with [byte].
class _Constant implements Random {
  const _Constant(this.byte);

  final int byte;

  @override
  int nextInt(int max) => byte;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  test('writes a version 4 UUID', () {
    // The server's `@IsUUID` accepts any version; a v4 is what this mints.
    final v4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    for (var i = 0; i < 100; i++) {
      final id = uuidV4();
      expect(v4.hasMatch(id), isTrue, reason: id);
    }
  });

  test('does not repeat', () {
    expect({for (var i = 0; i < 1000; i++) uuidV4()}, hasLength(1000));
  });

  test('sets the version and variant bits whatever the bytes', () {
    expect(
      uuidV4(const _Constant(0xff)),
      'ffffffff-ffff-4fff-bfff-ffffffffffff',
    );
    expect(
      uuidV4(const _Constant(0x00)),
      '00000000-0000-4000-8000-000000000000',
    );
  });
}
