// lib/services/websocket_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'time_service.dart';

enum WsState { disconnected, connecting, connected }

/// WebSocket-канал с автоматическим переподключением.
///
/// Токен передаётся в заголовке Authorization (не в URL). После каждого
/// успешного подключения вызывается [onConnected] — там клиент
/// досинхронизируется и отправляет outbox.
class WebSocketService extends ChangeNotifier {
  String baseUrl;

  WebSocketService({required this.baseUrl});

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  int _attempts = 0;
  String? _token;
  bool _running = false;
  int _generation = 0;

  WsState _state = WsState.disconnected;
  WsState get state => _state;
  bool get isConnected => _state == WsState.connected;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Вызывается после каждого успешного подключения.
  VoidCallback? onConnected;

  /// Вызывается, если сервер отверг сессию (401) — нужно перелогиниться.
  VoidCallback? onUnauthorized;

  final _random = Random();

  void start(String token) {
    _token = token;
    _running = true;
    _attempts = 0;
    _connect();
  }

  /// Полностью останавливает канал (без переподключений).
  void stop() {
    _running = false;
    _generation++;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setState(WsState.disconnected);
  }

  /// Немедленная попытка переподключения (например, при возврате в приложение).
  void reconnectNow() {
    if (!_running || _state != WsState.disconnected) return;
    _reconnectTimer?.cancel();
    _attempts = 0;
    _connect();
  }

  Future<void> _connect() async {
    if (!_running || _token == null) return;
    final gen = ++_generation;
    _setState(WsState.connecting);

    final wsUrl = baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final channel = IOWebSocketChannel.connect(
      Uri.parse('$wsUrl/ws'),
      headers: {'Authorization': 'Bearer $_token'},
      pingInterval: const Duration(seconds: 25),
      connectTimeout: const Duration(seconds: 10),
    );

    try {
      await channel.ready;
    } catch (e) {
      if (gen != _generation) return;
      // dart:io сообщает код ответа в тексте исключения (обёрнутого в
      // WebSocketChannelException), отдельного поля нет.
      if (e.toString().contains('status code: 401')) {
        debugPrint('WS: unauthorized');
        _running = false;
        _setState(WsState.disconnected);
        onUnauthorized?.call();
        return;
      }
      debugPrint('WS connect failed: $e');
      _scheduleReconnect();
      return;
    }
    if (gen != _generation) {
      channel.sink.close();
      return;
    }

    _channel = channel;
    _attempts = 0;
    _sub = channel.stream.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          final payload = msg['data'];
          if (payload is Map && payload['server_time'] is int) {
            TimeService().syncFromServerResponse(payload['server_time'] as int);
          }
          _messages.add(msg);
        } catch (e) {
          debugPrint('WS bad frame: $e');
        }
      },
      onError: (e) {
        if (gen == _generation) _onClosed();
      },
      onDone: () {
        if (gen == _generation) _onClosed();
      },
      cancelOnError: true,
    );
    _setState(WsState.connected);
    send('time_sync', {});
    onConnected?.call();
  }

  void _onClosed() {
    _sub?.cancel();
    _channel = null;
    _setState(WsState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _setState(WsState.disconnected);
    _reconnectTimer?.cancel();
    // Экспоненциальная задержка 1..30 с + случайный разброс.
    final base = min(30, 1 << min(_attempts, 5));
    final delay = Duration(milliseconds: base * 1000 + _random.nextInt(1000));
    _attempts++;
    _reconnectTimer = Timer(delay, _connect);
  }

  void _setState(WsState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }

  /// Отправляет сообщение. Возвращает false, если канал не подключён.
  bool send(String type, Map<String, dynamic> data) {
    final ch = _channel;
    if (ch == null || _state != WsState.connected) return false;
    ch.sink.add(jsonEncode({'type': type, 'data': data}));
    return true;
  }

  @override
  void dispose() {
    stop();
    _messages.close();
    super.dispose();
  }
}
