// Pins the one thing `Redaction.stripBoundValues` relies on: the text of a
// failing statement's error, as the drift and sqlite3 in this lockfile write
// it (#463). The helper recognises that text rather than the exception type,
// because a database running in a background isolate hides the type behind
// `DriftRemoteException`. A statement sent after the connection closed has a
// second shape, thrown by drift's isolate channel before sqlite is reached. So
// a `drift` or `sqlite3` upgrade that changes either format has to fail here,
// not leak bound values into a log quietly.
@TestOn('vm')
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

const _secret = 'bound-secret';

void main() {
  test('a statement failing on this drift keeps the shape the helper '
      'recognises', () async {
    final db = _TestDb(NativeDatabase.memory());
    addTearDown(db.close);

    final error = await _failOnDuplicate(db);
    final text = error.toString();

    expect(error, isA<SqliteException>());
    // A real leak, or the assertion below proves nothing.
    expect(text, contains(_secret));
    expect(Redaction.stripBoundValues(text), isNot(contains(_secret)));
    expect(Redaction.stripBoundValues(text), contains('Causing statement'));
  });

  test('the same through a background isolate, as native runs', () async {
    final directory = await Directory.systemTemp.createTemp('bge_bound_');
    addTearDown(() => directory.delete(recursive: true));
    final db = _TestDb(
      NativeDatabase.createInBackground(File('${directory.path}/t.db')),
    );
    addTearDown(db.close);

    final error = await _failOnDuplicate(db);
    final text = error.toString();

    expect(error, isA<DriftRemoteException>());
    expect(text, contains(_secret));
    expect(Redaction.stripBoundValues(text), isNot(contains(_secret)));
    expect(Redaction.stripBoundValues(text), contains('Causing statement'));
  });

  test('a statement sent after a background isolate database closed keeps '
      'the shape the helper recognises', () async {
    final directory = await Directory.systemTemp.createTemp('bge_bound_');
    addTearDown(() => directory.delete(recursive: true));
    final db = _TestDb(
      NativeDatabase.createInBackground(File('${directory.path}/t.db')),
    );
    await db.customStatement('CREATE TABLE t (a TEXT, b TEXT)');
    await db.close();

    final error = await _failAfterClose(db);
    final text = error.toString();

    // Not a SqliteException, and no `Causing statement`: a different shape.
    expect(error, isNot(isA<SqliteException>()));
    expect(text, isNot(contains('Causing statement')));
    expect(text, contains('Tried to send Request'));
    // A real leak, or the assertions below prove nothing.
    expect(text, contains(_secret));
    final stripped = Redaction.stripBoundValues(text);
    expect(stripped, isNot(contains(_secret)));
    expect(stripped, contains('INSERT INTO t'));
  });
}

/// Runs an insert binding [_secret] on a closed [db], and returns what it
/// threw.
Future<Object> _failAfterClose(_TestDb db) async {
  try {
    await db.customStatement('INSERT INTO t (a, b) VALUES (?, ?)', [
      _secret,
      'other',
    ]);
  } on Object catch (error) {
    return error;
  }
  fail('a statement on a closed database should have thrown');
}

/// Inserts [_secret] into a unique column twice, and returns what the second
/// insert threw.
Future<Object> _failOnDuplicate(_TestDb db) async {
  await db.customStatement('CREATE TABLE t (a TEXT UNIQUE)');
  await db.customStatement('INSERT INTO t (a) VALUES (?)', [_secret]);
  try {
    await db.customStatement('INSERT INTO t (a) VALUES (?)', [_secret]);
  } on Object catch (error) {
    return error;
  }
  fail('the second insert should have broken the unique column');
}

/// A database with no generated tables: the test makes its own through
/// `customStatement`.
class _TestDb extends GeneratedDatabase {
  _TestDb(super.executor);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 1;
}
