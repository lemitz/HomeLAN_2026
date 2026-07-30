import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'time_service.dart';

class WebSocketService {
  final String baseUrl;
  WebSocketChannel? _channel;
  
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _timeSyncTimer;  // NEW: Таймер для ресинхронизации времени
  int _reconnectAttempts = 0;
  
  int? _userId;
  String? _deviceId;
  String? _token;

  // Callback для уведомлений о новых сообщениях
  Function(Map<String, dynamic> message)? onNewMessage;

  WebSocketService({required this.baseUrl});

  Future<void> connect({
    required int userId,
    required String deviceId,
    required String token,
  }) async {
    _userId = userId;
    _deviceId = deviceId;
    _token = token;
    _reconnectAttempts = 0;
    
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_userId == null || _deviceId == null) return;
    
    try {
      final wsUrl = baseUrl.replaceFirst('http', 'ws');
      final uri = Uri.parse('$wsUrl/ws?user_id=$_userId&device_id=$_deviceId&token=$_token');
      
      _channel = WebSocketChannel.connect(uri);
      
      _channel!.stream.listen(
        (data) {
          _isConnected = true;
          _reconnectAttempts = 0;
          
          final message = jsonDecode(data as String);
          
          // NEW: Синхронизируем время из любого ответа сервера
          _syncTimeFromMessage(message);
          
          // Вызываем callback для новых сообщений (для уведомлений)
          if (message['type'] == 'new_message' && onNewMessage != null) {
            onNewMessage!(message['data']);
          }
          
          _messageController.add(message);
        },
        onError: (error) {
          print('WebSocket error: $error');
          _isConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          print('WebSocket closed');
          _isConnected = false;
          _scheduleReconnect();
        },
      );
      
      _isConnected = true;
      _startPingTimer();
      _startTimeSyncTimer();  // NEW
      
      // NEW: Запрашиваем время сразу при подключении
      _requestTimeSync();
      
      print('WebSocket connected');
    } catch (e) {
      print('WebSocket connection error: $e');
      _isConnected = false;
      _scheduleReconnect();
    }
  }

  // NEW: Синхронизация времени из сообщения сервера
  void _syncTimeFromMessage(Map<String, dynamic> message) {
    // Проверяем server_time в корне сообщения
    if (message['server_time'] != null) {
      TimeService().syncFromServerResponse(message['server_time']);
      return;
    }
    
    // Проверяем в data
    if (message['data'] != null && message['data']['server_time'] != null) {
      TimeService().syncFromServerResponse(message['data']['server_time']);
      return;
    }
    
    // Для pong ответа
    if (message['type'] == 'pong' && message['timestamp'] != null) {
      TimeService().syncFromServerResponse(message['timestamp']);
    }
  }

  // NEW: Периодическая ресинхронизация времени (каждые 6 часов)
  void _startTimeSyncTimer() {
    _timeSyncTimer?.cancel();
    _timeSyncTimer = Timer.periodic(const Duration(hours: 6), (_) {
      if (_isConnected) {
        _requestTimeSync();
      }
    });
  }

  // NEW: Запрос времени сервера
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
    _reconnectTimer?.cancel();
    _timeSyncTimer?.cancel();  // NEW: Останавливаем sync при дисконнекте
    
    // Exponential backoff: 1s, 2s, 4s, 8s, max 30s
    final delay = Duration(
      seconds: (_reconnectAttempts < 5) 
          ? (1 << _reconnectAttempts) 
          : 30,
    );
    
    _reconnectAttempts++;
    
    _reconnectTimer = Timer(delay, () {
      if (!_isConnected && _userId != null) {
        print('Reconnecting (attempt $_reconnectAttempts)...');
        _doConnect();
      }
    });
  }

  void send(Map<String, dynamic> message) {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void sendMessage({
    required int recipientId,
    required String content,
    String contentType = 'text',
    String? fileId,
  }) {
    send({
      'type': 'send_message',
      'data': {
        'recipient_id': recipientId,
        'encrypted_content': base64Encode(utf8.encode(content)),
        'content_type': contentType,
        'timestamp': TimeService().getNow(),  // NEW: Используем синхронизированное время
        if (fileId != null) 'file_id': fileId,
      },
    });
  }

  void sendEncryptedMessage({
    required int recipientId,
    required Uint8List encryptedContent,
    String contentType = 'encrypted',
    String? fileId,
  }) {
    send({
      'type': 'send_message',
      'data': {
        'recipient_id': recipientId,
        'encrypted_content': base64Encode(encryptedContent),
        'content_type': contentType,
        'timestamp': TimeService().getNow(),  // NEW: Используем синхронизированное время
        if (fileId != null) 'file_id': fileId,
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
      'data': {
        'recipient_id': recipientId,
      },
    });
  }

  void disconnect() {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _timeSyncTimer?.cancel();  // NEW
    _channel?.sink.close();
    _isConnected = false;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}