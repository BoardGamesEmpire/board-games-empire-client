import 'dependency_container.dart';
import 'server_context_state.dart';

/// Encapsulates the isolated dependency injection scope, storage, networking,
/// and lifecycle state for a single server instance
abstract class ServerContext {
  /// Unique identifier matching the ServerConfig this context represents
  String get serverId;

  /// Current lifecycle state indicating resource allocation level
  ServerContextState get state;

  /// Dependency injection container holding all server-specific services
  /// including repositories, network clients, and storage managers
  ///
  /// Consumers retrieve dependencies through context.container.get<T>()
  /// ensuring all resolution occurs within this server's isolated scope
  DependencyContainer get container;

  /// Transitions this context to active state by initializing full foreground
  /// services and establishing primary network connections
  Future<void> activate();

  /// Transitions this context to monitoring state by downgrading to minimal
  /// background services while maintaining notification connectivity
  Future<void> suspend();

  /// Fully disposes this context by closing all network connections, flushing
  /// pending storage operations, and releasing the dependency container
  Future<void> dispose();

  /// Stream emitting lifecycle state changes for observation by components
  /// that need to adapt behavior based on whether this context is active,
  /// monitoring, or transitioning between states
  Stream<ServerContextState> watchState();
}
