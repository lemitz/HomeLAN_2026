// lib/services/connection_service.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../l10n/strings.dart';

enum ServerConnectionState {
  unknown,
  checking,
  connected,
  disconnected,
}

class ConnectionService with ChangeNotifier {
  static final ConnectionService _instance = ConnectionService._internal();
  factory ConnectionService() => _instance;
  ConnectionService._internal();

  ServerConnectionState _state = ServerConnectionState.unknown;
  Timer? _healthTimer;
  int _failedChecks = 0;
  DateTime? _lastSuccess;
  String? _disconnectReason;
  String _serverUrl = '';

  static const int maxFailedChecks = 2;
  static const Duration checkInterval = Duration(seconds: 4);
  static const Duration timeout = Duration(seconds: 3);

  ServerConnectionState get state => _state;
  bool get isConnected => _state == ServerConnectionState.connected;
  bool get isDisconnected => _state == ServerConnectionState.disconnected;
  String? get disconnectReason => _disconnectReason;
  DateTime? get lastSuccess => _lastSuccess;

  void init(String serverUrl) {
    _serverUrl = serverUrl;
  }

  Future<bool> startMonitoring() async {
    if (_serverUrl.isEmpty) return false;

    if (_state != ServerConnectionState.connected) _setState(ServerConnectionState.checking);
    // Таймер работает всегда — при недоступном сервере проверки продолжаются,
    // и связь восстанавливается автоматически.
    _startTimer();

    final alive = await _checkHealth();
    if (!alive) {
      _disconnectReason = S.current.serverNotResponding;
      _setState(ServerConnectionState.disconnected);
      return false;
    }

    _failedChecks = 0;
    _lastSuccess = DateTime.now();
    _setState(ServerConnectionState.connected);
    return true;
  }

  void stopMonitoring() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _setState(ServerConnectionState.unknown);
  }

  void onServerMessage() {
    _lastSuccess = DateTime.now();
    _failedChecks = 0;

    if (_state == ServerConnectionState.disconnected) {
      _setState(ServerConnectionState.connected);
    }
  }

  void _startTimer() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(checkInterval, (_) => _doCheck());
  }

  Future<void> _doCheck() async {
    final alive = await _checkHealth();

    if (alive) {
      _failedChecks = 0;
      _lastSuccess = DateTime.now();

      if (_state != ServerConnectionState.connected) {
        _setState(ServerConnectionState.connected);
      }
    } else {
      _failedChecks++;
      if (_failedChecks >= maxFailedChecks || _state != ServerConnectionState.connected) {
        _disconnectReason = S.current.serverNotResponding;
        _setState(ServerConnectionState.disconnected);
      }
    }
  }

  Future<bool> _checkHealth() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse('$_serverUrl/health')).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (e) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> tryReconnect() async {
    _failedChecks = 0;
    return await startMonitoring();
  }

  void _setState(ServerConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      notifyListeners();
    }
  }
}
