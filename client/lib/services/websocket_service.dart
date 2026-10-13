import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/io.dart';
import '../utils/app_log.dart';
import 'time_service.dart';

/// WebSocket-клиент сервера HomeLAN.
///
/// Токен передаётся ТОЛЬКО в заголовке `Authorization` (сервер больше не
/// принимает его в query-строке). [baseUrl] можно менять на лету — следующий
/// (пере)коннект использует новое значение.
class WebSocketService {
  String baseUrl;
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _timeSyncTimer;
  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;
  bool _connecting = false;
  bool _manuallyClosed = true;

  /// Номер поколения соединения: защищает от гонки, когда старый connect()
  /// завершается уже после disconnect()/нового connect().
  int _generation = 0;

  int? _userId;
  String? _deviceId;
  String? _token;

  /// Callback для уведомлений о новых сообщениях
  Function(Map<String, dynamic> message)? onNewMessage;

  /// Вызывается после каждого успешного (пере)подключения
  void Function()? onConnected;

  /// Вызывается, когда подключиться не удаётся несколько раз подряд
  /// (например, токен отозван — сервер отвечает 401/403 на upgrade).
  /// AuthProvider по этому сигналу перепроверяет сессию через REST.
  void Function(int consecutiveFailures)? onPersistentFailure;

  static const int persistentFailureThreshold = 3;

  WebSocketService({required this.baseUrl});

  Future<void> connect({
    required int userId,
    required String deviceId,
    required String token,
  }) async {
    // Закрываем предыдущее соединение (повторный логин, смена адреса и т.п.)
    await _closeChannel();

    _userId = userId;
    _deviceId = deviceId;
    _token = token;
    _reconnectAttempts = 0;
    _consecutiveFailures = 0;
    _manuallyClosed = false;

    await _doConnect();
  }

  String get _wsBase {
    if (baseUrl.startsWith('https://')) {
      return 'wss://${baseUrl.substring('https://'.length)}';
    }
    if (baseUrl.startsWith('http://')) {
      return 'ws://${baseUrl.substring('http://'.length)}';
    }
    return 'ws://$baseUrl';
  }

  Future<void> _doConnect() async {
    if (_manuallyClosed || _connecting) return;
    if (_userId == null || _deviceId == null || _token == null) return;

    _connecting = true;
    final generation = ++_generation;

    try {
      final uri = Uri.parse('$_wsBase/ws?device_id=${Uri.encodeQueryComponent(_deviceId!)}');

      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Authorization': 'Bearer $_token'},
        connectTimeout: const Duration(seconds: 10),
      );

      // Ждём реального завершения handshake: до этого sink.add молча терялся,
      // а ошибки 401/403 выглядели как «подключились и сразу отвалились».
      await channel.ready;

      if (generation != _generation || _manuallyClosed) {
        // Пока подключались — вызвали disconnect()/connect() заново
        await channel.sink.close();
        return;
      }

      _channel = channel;
      _isConnected = true;
      _reconnectAttempts = 0;
      _consecutiveFailures = 0;

      _subscription = channel.stream.listen(
        (data) {
          if (generation != _generation) return;
          try {
            final message = jsonDecode(data as String);
            if (message is! Map<String, dynamic>) return;

            _syncTimeFromMessage(message);

            if (message['type'] == 'new_message' && onNewMessage != null) {
              final payload = message['data'];
              if (payload is Map<String, dynamic>) {
                onNewMessage!(payload);
              }
            }

            _messageController.add(message);
          } catch (e) {
            appLog('WebSocket: bad frame: $e');
          }
        },
        onError: (error) {
          if (generation != _generation) return;
          appLog('WebSocket error: $error');
          _isConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          if (generation != _generation) return;
          appLog('WebSocket closed');
          _isConnected = false;
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _startPingTimer();
      _startTimeSyncTimer();
      _requestTimeSync();

      appLog('WebSocket connected');
      onConnected?.call();
    } catch (e) {
      appLog('WebSocket connection error: $e');
      _isConnected = false;
      _consecutiveFailures++;
      if (_consecutiveFailures >= persistentFailureThreshold &&
          (_consecutiveFailures - persistentFailureThreshold) % 5 == 0) {
        onPersistentFailure?.call(_consecutiveFailures);
      }
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  /// Синхронизация времени из сообщения сервера
  void _syncTimeFromMessage(Map<String, dynamic> message) {
    final root = message['server_time'];
    if (root is int) {
      TimeService().syncFromServerResponse(root);
      return;
    }

    final data = message['data'];
    if (data is Map && data['server_time'] is int) {
      TimeService().syncFromServerResponse(data['server_time'] as int);
      return;
    }

    if (message['type'] == 'pong' && message['timestamp'] is int) {
      TimeService().syncFromServerResponse(message['timestamp'] as int);
    }
  }

  /// Периодическая ресинхронизация времени (каждые 6 часов)
  void _startTimeSyncTimer() {
    _timeSyncTimer?.cancel();
    _timeSyncTimer = Timer.periodic(const Duration(hours: 6), (_) {
      if (_isConnected) {
        _requestTimeSync();
      }
    });
  }

  void _requestTimeSync() {
    send({
      'type': 'time_sync',
      'data': {
        'client_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
    });
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_isConnected) {
        send({'type': 'ping', 'data': {}});
      }
    });
  }

  void _scheduleReconnect() {
    if (_manuallyClosed) return;

    _reconnectTimer?.cancel();
    _timeSyncTimer?.cancel();
    _pingTimer?.cancel();

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, затем 30s
    final delay = Duration(
      seconds: (_reconnectAttempts < 5) ? (1 << _reconnectAttempts) : 30,
    );
    _reconnectAttempts++;

    _reconnectTimer = Timer(delay, () {
      if (!_isConnected && !_manuallyClosed && _userId != null) {
        appLog('WebSocket: reconnecting (attempt $_reconnectAttempts)...');
        _doConnect();
      }
    });
  }

  /// Принудительно переподключиться (например, после смены адреса сервера)
  Future<void> reconnectNow() async {
    if (_userId == null || _deviceId == null || _token == null) return;
    final userId = _userId!;
    final deviceId = _deviceId!;
    final token = _token!;
    await connect(userId: userId, deviceId: deviceId, token: token);
  }

  /// Отправляет сообщение. Возвращает false, если соединения нет —
  /// вызывающая сторона решает, ставить ли сообщение в очередь.
  bool send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || !_isConnected) return false;
    try {
      channel.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      appLog('WebSocket send error: $e');
      return false;
    }
  }

  /// Отправка зашифрованного сообщения.
  ///
  /// Открытый текст через WebSocket не отправляется принципиально:
  /// метод для plaintext удалён.
  bool sendEncryptedMessage({
    required int recipientId,
    required Uint8List encryptedContent,
    String contentType = 'encrypted',
    String? fileId,
    String? clientId,
  }) {
    return send({
      'type': 'send_message',
      'data': {
        'recipient_id': recipientId,
        'encrypted_content': base64Encode(encryptedContent),
        'content_type': contentType,
        if (fileId != null) 'file_id': fileId,
        if (clientId != null) 'client_id': clientId,
      },
    });
  }

  void sync({int sinceSeqId = 0, int limit = 100}) {
    send({
      'type': 'sync',
      'data': {
        'since_seq_id': sinceSeqId,
        'limit': limit,
      },
    });
  }

  void syncBefore({required int beforeSeqId, int limit = 50}) {
    send({
      'type': 'sync',
      'data': {
        'before_seq_id': beforeSeqId,
        'limit': limit,
      },
    });
  }

  void ack(int seqId) {
    send({
      'type': 'ack',
      'data': {'seq_id': seqId},
    });
  }

  void markRead(int seqId) {
    send({
      'type': 'read',
      'data': {'seq_id': seqId},
    });
  }

  void deleteMessage(int seqId) {
    send({
      'type': 'delete',
      'data': {'seq_id': seqId},
    });
  }

  void sendTyping(int recipientId) {
    send({
      'type': 'typing',
      'data': {'recipient_id': recipientId},
    });
  }

  Future<void> _closeChannel() async {
    _generation++;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _timeSyncTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    _isConnected = false;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }

  /// Полное отключение: закрывает сокет, отменяет таймеры переподключения
  /// и забывает учётные данные. После logout старый токен не должен
  /// «воскрешать» соединение из отложенного reconnect-таймера.
  Future<void> disconnect() async {
    _manuallyClosed = true;
    await _closeChannel();
    _userId = null;
    _deviceId = null;
    _token = null;
    _reconnectAttempts = 0;
    _consecutiveFailures = 0;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
