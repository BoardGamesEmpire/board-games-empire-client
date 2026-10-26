import 'package:models/domain.dart';
import 'package:test/test.dart';

/// Registers one enum's read contract (#43) as a group of two tests.
///
/// [byWire] is written out by hand from the backend's own enum, so an arm of
/// `fromWire` that is mistyped, or that maps to the wrong value, fails here.
/// The table must also name every value but [unknown]: `fromWire` ends in a
/// `_` arm, so a value left out of its switch would otherwise read as unknown
/// without failing anything.
void _readContract<T extends Enum>({
  required Map<String, T> byWire,
  required List<T> values,
  required T unknown,
  required T Function(String) fromWire,
  required String unrecognised,
}) {
  group('$T', () {
    test('fromWire reads every server name', () {
      for (final MapEntry(key: wire, value: expected) in byWire.entries) {
        expect(fromWire(wire), expected, reason: '$T.fromWire("$wire")');
      }
      expect(
        byWire.values.toSet(),
        values.where((value) => value != unknown).toSet(),
        reason: 'every $T but unknown should have a server name',
      );
    });

    test('fromWire reads an unknown name as unknown', () {
      expect(fromWire(unrecognised), unknown);
    });
  });
}

void main() {
  // `JobStatus` in prisma/models/system/job.prisma.
  _readContract<ImportJobStatus>(
    byWire: const {
      'Pending': ImportJobStatus.pending,
      'Running': ImportJobStatus.running,
      'Completed': ImportJobStatus.completed,
      'Failed': ImportJobStatus.failed,
      'Cancelled': ImportJobStatus.cancelled,
    },
    values: ImportJobStatus.values,
    unknown: ImportJobStatus.unknown,
    fromWire: ImportJobStatus.fromWire,
    unrecognised: 'Paused',
  );

  // `ImportBatchStatus` in libs/api/game-import's import-job.interface.ts.
  _readContract<ImportBatchStatus>(
    byWire: const {
      'Pending': ImportBatchStatus.pending,
      'Running': ImportBatchStatus.running,
      'Completed': ImportBatchStatus.completed,
      'PartiallyCompleted': ImportBatchStatus.partiallyCompleted,
      'Failed': ImportBatchStatus.failed,
      'Cancelled': ImportBatchStatus.cancelled,
    },
    values: ImportBatchStatus.values,
    unknown: ImportBatchStatus.unknown,
    fromWire: ImportBatchStatus.fromWire,
    unrecognised: 'Paused',
  );

  // `ImportErrorCode` in libs/api/game-import's sanitize-import-error.ts.
  _readContract<ImportErrorCode>(
    byWire: const {
      'NOT_FOUND': ImportErrorCode.notFound,
      'GATEWAY_ERROR': ImportErrorCode.gatewayError,
      'INTERNAL_ERROR': ImportErrorCode.internalError,
      'BASE_IMPORT_FAILED': ImportErrorCode.baseImportFailed,
    },
    values: ImportErrorCode.values,
    unknown: ImportErrorCode.unknown,
    fromWire: ImportErrorCode.fromWire,
    unrecognised: 'TIMEOUT',
  );

  group('ImportBatch', () {
    ImportJob job(String id, {required bool isExpansion}) => ImportJob(
      jobId: id,
      status: ImportJobStatus.running,
      isExpansion: isExpansion,
      externalId: 'ext_$id',
    );

    ImportBatch batchOf(List<ImportJob> jobs) => ImportBatch(
      batchId: '0b7c2f9e-3a41-4c8e-9d2a-5f6b7c8d9e0f',
      correlationId: '5a1e4b3c-2d6f-4a8b-9c0d-1e2f3a4b5c6d',
      status: ImportBatchStatus.running,
      jobs: jobs,
    );

    test('baseJob is the job that is not an expansion', () {
      final e1 = job('e1', isExpansion: true);
      final b1 = job('b1', isExpansion: false);

      expect(batchOf([e1, b1]).baseJob, b1);
    });

    test('baseJob is null when the server listed no base job', () {
      expect(batchOf([job('e1', isExpansion: true)]).baseJob, isNull);
    });
  });
}
