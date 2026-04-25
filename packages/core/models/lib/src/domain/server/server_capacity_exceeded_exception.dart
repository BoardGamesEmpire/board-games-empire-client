class ServerCapacityExceededException implements Exception {
  final int currentConnected;
  final int maxCapacity;
  final String message;

  const ServerCapacityExceededException({
    required this.currentConnected,
    required this.maxCapacity,
  }) : message =
           'Cannot monitor additional servers. Currently monitoring '
           '$currentConnected of $maxCapacity allowed. Disconnect an existing '
           'monitored server before connecting another.';

  @override
  String toString() => 'ServerCapacityExceededException: $message';
}
