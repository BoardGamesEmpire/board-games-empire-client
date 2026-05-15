import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

const _kBgeServerId = '550e8400-e29b-41d4-a716-446655440000';
const _kServerUrl = 'https://api.example.com';

ServerIdentity _makeIdentity({
  String serverId = _kBgeServerId,
  String issuer = _kServerUrl,
}) => ServerIdentity(
  serverId: serverId,
  issuer: issuer,
  deviceAuthorizationEndpoint: '$issuer/api/auth/device',
  authBaseUrl: '$issuer/api/auth',
  sessionEndpoint: '$issuer/api/auth/get-session',
  signOutEndpoint: '$issuer/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

void main() {
  group('ServerConfig', () {
    test('creates with required fields', () {
      final config = ServerConfig(
        id: 'server_123',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        displayName: 'Production Server',
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.disconnected,
      );

      expect(config.id, 'server_123');
      expect(config.displayName, 'Production Server');
      expect(config.serverUrl, 'https://api.example.com');
      expect(config.connectionState, ConnectionState.disconnected);
      expect(config.metadata, isEmpty);
    });

    test('serializes to JSON with enum mapping', () {
      final config = ServerConfig(
        id: 'server_123',
        displayName: 'Test Server',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.monitoring,
        lastActiveAt: DateTime.parse('2024-01-15T10:30:00Z'),
        metadata: {'region': 'us-east'},
      );

      final json = config.toJson();

      expect(json['id'], 'server_123');
      expect(json['connectionState'], 'Monitoring');
      expect(json['metadata']['region'], 'us-east');
    });

    test('deserializes from JSON', () {
      final json = {
        'id': 'server_456',
        'displayName': 'Staging',
        'serverUrl': 'https://staging.example.com',
        'connectionState': 'Active',
        'bgeServerId': _kBgeServerId,
        'cachedIdentity': {
          'bge_server_id': _kBgeServerId,
          'issuer': 'https://staging.example.com',
          'device_authorization_endpoint':
              'https://staging.example.com/api/auth/device',
          'bge_auth_base_url': 'https://staging.example.com/api/auth',
          'bge_session_endpoint':
              'https://staging.example.com/api/auth/get-session',
          'bge_sign_out_endpoint':
              'https://staging.example.com/api/auth/sign-out',
          'bge_passkey_supported': true,
          'bge_two_factor_supported': true,
          'bge_anonymous_auth_supported': true,
        },
        'lastIdentityFetchedAt': '2024-01-15T10:30:00Z',
        'lastActiveAt': '2024-01-15T10:30:00Z',
        'metadata': {'environment': 'staging'},
      };

      final config = ServerConfig.fromJson(json);

      expect(config.connectionState, ConnectionState.active);
      expect(config.lastActiveAt, isNotNull);
      expect(config.metadata['environment'], 'staging');
    });

    test('computes connection state predicates correctly', () {
      final activeConfig = ServerConfig(
        id: 'active',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        displayName: 'Active',
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.active,
      );

      expect(activeConfig.isActive, isTrue);
      expect(activeConfig.isMonitoring, isFalse);
      expect(activeConfig.isDisconnected, isFalse);
      expect(activeConfig.isConnected, isTrue);

      final monitoringConfig = activeConfig.copyWith(
        connectionState: ConnectionState.monitoring,
      );

      expect(monitoringConfig.isActive, isFalse);
      expect(monitoringConfig.isMonitoring, isTrue);
      expect(monitoringConfig.isDisconnected, isFalse);
      expect(monitoringConfig.isConnected, isTrue);

      final disconnectedConfig = activeConfig.copyWith(
        connectionState: ConnectionState.disconnected,
      );

      expect(disconnectedConfig.isActive, isFalse);
      expect(disconnectedConfig.isMonitoring, isFalse);
      expect(disconnectedConfig.isDisconnected, isTrue);
      expect(disconnectedConfig.isConnected, isFalse);
    });

    test('generates correct database path', () {
      final config = ServerConfig(
        id: 'server_abc123',
        displayName: 'Test',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.disconnected,
      );

      expect(
        config.databasePath,
        'app_secure_storage/server_abc123/game_empire.db',
      );
    });

    test('maintains immutability through copyWith', () {
      final original = ServerConfig(
        id: 'server_1',
        displayName: 'Original',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.disconnected,
      );

      final modified = original.copyWith(
        displayName: 'Modified',
        connectionState: ConnectionState.active,
      );

      expect(original.displayName, 'Original');
      expect(original.connectionState, ConnectionState.disconnected);
      expect(modified.displayName, 'Modified');
      expect(modified.connectionState, ConnectionState.active);
      expect(modified.id, original.id);
      expect(modified.serverUrl, original.serverUrl);
    });

    test('handles optional metadata', () {
      final withMetadata = ServerConfig(
        id: 'server_1',
        displayName: 'Test',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.disconnected,
        metadata: {
          'region': 'us-west',
          'tier': 'premium',
          'features': ['chat', 'analytics'],
        },
      );

      expect(withMetadata.metadata['region'], 'us-west');
      expect(withMetadata.metadata['features'], hasLength(2));

      final withoutMetadata = ServerConfig(
        id: 'server_2',
        displayName: 'Minimal',
        bgeServerId: _kBgeServerId,
        cachedIdentity: _makeIdentity(),
        lastIdentityFetchedAt: DateTime.now().toUtc(),
        serverUrl: _kServerUrl,
        connectionState: ConnectionState.disconnected,
      );

      expect(withoutMetadata.metadata, isEmpty);
    });
  });

  group('ServerCapacityExceededException', () {
    test('formats message correctly', () {
      final exception = ServerCapacityExceededException(
        currentConnected: 5,
        maxCapacity: 5,
      );

      expect(exception.currentConnected, 5);
      expect(exception.maxCapacity, 5);
      expect(
        exception.message,
        contains('Currently monitoring 5 of 5 allowed'),
      );
      expect(
        exception.message,
        contains('Disconnect an existing monitored server'),
      );
    });
  });
}
