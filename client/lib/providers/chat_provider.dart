// lib/providers/chat_provider.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../utils/app_log.dart';

/// Префикс, которым помечаются входящие сообщения, пришедшие без шифрования.
/// Текущий клиент такие сообщения не отправляет, но их мог прислать старый
/// клиент или кто-то, подключившийся к серверу напрямую.
const String unencryptedMarker = '⚠️ [незашифровано] ';

/// Ошибка отправки, которую можно показать пользователю
class SendMessageException implements Exception {
  final String message;
  SendMessageException(this.message);
  @override
  String toString() => message;
}

class _PendingSend {
  final int recipientId;
  final Uint8List encryptedContent;
  final String contentType;
  final String? fileId;
  final String clientId;

  _PendingSend({
    required this.recipientId,
    required this.encryptedContent,
    required this.contentType,
    required this.clientId,
    this.fileId,
  });
}

class ChatProvider with ChangeNotifier {
  final WebSocketService _ws;
  final DatabaseService _db;
  final ApiService _api;
  final CryptoService _crypto;
  final NotificationService _notifications;

  int? _myUserId;
  final Map<int, List<Message>> _chats = {};
  final Map<int, String> _usernames = {};
  StreamSubscription? _wsSubscription;
  bool _isLoading = false;

  int? _activeChatUserId;

  final Map<int, bool> _hasMoreMessages = {};
  final Map<int, bool> _isLoadingMore = {};

  final Map<int, DateTime> _typingUsers = {};

  final Map<int, Map<String, dynamic>> _contactSettings = {};

  int _myBubbleColor = Colors.blue.value;
  int _otherBubbleColor = Colors.grey[800]!.value;

  bool _notificationsEnabled = true;

  /// Сообщения, которые не удалось передать в сокет (не было соединения).
  /// Отправляются при следующем подключении. Сюда попадают ТОЛЬКО сообщения,
  /// которые гарантированно не ушли, поэтому дублей не возникает.
  final List<_PendingSend> _unsentQueue = [];

  /// Защита от бесконечной forward-синхронизации
  int _forwardSyncPages = 0;
  static const int _maxForwardSyncPages = 200;

  // КЛЮЧЕВОЙ ГЕТТЕР: на Windows без связи — пустые чаты
  Map<int, List<Message>> get chats {
    if (Platform.isWindows && !ConnectionService().isConnected) {
      return {};
    }
    return _chats;
  }

  Map<int, String> get usernames => _usernames;
  bool get isLoading => _isLoading;
  int? get myUserId => _myUserId;

  int get myBubbleColor => _myBubbleColor;
  int get otherBubbleColor => _otherBubbleColor;

  bool get notificationsEnabled => _notificationsEnabled;

  bool isUserTyping(int userId) {
    final lastTyping = _typingUsers[userId];
    if (lastTyping == null) return false;
    return DateTime.now().difference(lastTyping).inSeconds < 3;
  }

  ChatProvider({
    required WebSocketService ws,
    required DatabaseService db,
    required ApiService api,
    required CryptoService crypto,
    required NotificationService notifications,
  })  : _ws = ws,
        _db = db,
        _api = api,
        _crypto = crypto,
        _notifications = notifications {
    _listenToWebSocket();
    _listenToConnectionChanges();
    _ws.onConnected = _onWsConnected;
    loadBubbleColors();
    _loadNotificationSettings();
  }

  void _listenToConnectionChanges() {
    if (Platform.isWindows) {
      ConnectionService().addListener(_onConnectionChanged);
    }
  }

  void _onConnectionChanged() {
    // При изменении состояния соединения — обновляем UI
    notifyListeners();
  }

  /// После (пере)подключения: досылаем неотправленное и догоняем историю
  void _onWsConnected() {
    if (_myUserId == null) return;
    _flushUnsentQueue();
    _syncMessages();
  }

  void setUserId(int userId) {
    _myUserId = userId;
    appLog('ChatProvider: setUserId=$userId');
    _loadAllDataFromDB();
    _syncMessages();
  }

  Future<void> _loadAllDataFromDB() async {
    if (_myUserId == null) return;

    final savedUsernames = await _db.getAllUsernames();
    _usernames.addAll(savedUsernames);

    final savedContacts = await _db.getAllContacts();
    _contactSettings.addAll(savedContacts);

    final chatUserIds = await _db.getAllChatUserIds(_myUserId!);

    for (final oderId in chatUserIds) {
      final messages = await _db.getMessages(oderId, _myUserId!);
      if (messages.isNotEmpty) {
        _chats[oderId] = messages;
      }
    }

    notifyListeners();
  }

  void setActiveChat(int? userId) {
    _activeChatUserId = userId;

    if (userId != null) {
      _notifications.cancelNotificationsFromUser(userId);
    }
  }

  Future<void> _ensureUserPublicKey(int userId) async {
    if (_crypto.hasUserPublicKey(userId)) return;

    try {
      final userData = await _api.getUser(userId);
      if (userData['public_key'] != null) {
        final publicKeyBase64 = userData['public_key'] as String;
        _crypto.setUserPublicKeyBase64(userId, publicKeyBase64);
        appLog('🔐 Fetched public key for user $userId');
      }
    } catch (e) {
      appLog('Failed to fetch public key for user $userId: $e');
    }
  }

  void _listenToWebSocket() {
    _wsSubscription = _ws.messages.listen((message) {
      final type = message['type'];
      final data = message['data'];

      // Уведомляем ConnectionService о сообщении
      if (Platform.isWindows) {
        ConnectionService().onServerMessage();
      }

      if (data is! Map<String, dynamic>) return;

      switch (type) {
        case 'new_message':
          _handleNewMessage(data);
          break;
        case 'message_sent':
          _handleMessageSent(data);
          break;
        case 'sync_response':
          _handleSyncResponse(data);
          break;
        case 'status_update':
          _handleStatusUpdate(data);
          break;
        case 'message_deleted':
          _handleMessageDeleted(data);
          break;
        case 'user_typing':
          _handleUserTyping(data);
          break;
        case 'error':
          appLog('WS server error: ${data['code']}: ${data['message']}');
          break;
      }
    });
  }

  Future<void> _handleNewMessage(Map<String, dynamic> data) async {
    final message = Message.fromJson(data);

    final oderId = message.senderId == _myUserId
        ? message.recipientId
        : message.senderId;

    _chats[oderId] ??= [];

    final exists = _chats[oderId]!.any((m) => m.seqId == message.seqId);
    if (!exists) {
      final messageWithStatus = message.senderId != _myUserId
          ? message.copyWith(status: 'delivered')
          : message;

      _chats[oderId]!.insert(0, messageWithStatus);
      _db.insertMessage(messageWithStatus);

      // Подтверждение доставки ставит только получатель
      if (message.senderId != _myUserId) {
        _ws.ack(message.seqId);
        _typingUsers.remove(message.senderId);
      }

      if (message.senderId != _myUserId && _activeChatUserId != message.senderId) {
        await _showNotificationForMessage(message);
      }

      if (message.senderId != _myUserId && _activeChatUserId == message.senderId) {
        markAsRead(message.seqId);
      }
    }

    notifyListeners();
  }

  void _handleUserTyping(Map<String, dynamic> data) {
    final userId = data['user_id'];
    if (userId is! int) return;
    _typingUsers[userId] = DateTime.now();
    notifyListeners();

    Future.delayed(const Duration(seconds: 3), () {
      if (_typingUsers[userId]?.isBefore(
            DateTime.now().subtract(const Duration(seconds: 3)),
          ) ??
          false) {
        _typingUsers.remove(userId);
        notifyListeners();
      }
    });
  }

  Future<void> _showNotificationForMessage(Message message) async {
    if (!_notificationsEnabled) return;

    try {
      final senderId = message.senderId;
      final senderName = getContactName(senderId, _usernames[senderId] ?? 'User $senderId');

      String messageText = '';
      bool isImage = false;
      bool isFile = false;

      if (message.contentType.contains('image')) {
        isImage = true;
      } else if (message.contentType.contains('file')) {
        isFile = true;
      } else {
        try {
          messageText = await decryptMessage(message);
          if (messageText.startsWith('[')) {
            messageText = 'Новое сообщение';
          }
        } catch (e) {
          messageText = 'Новое сообщение';
        }
      }

      await _notifications.showMessageNotification(
        senderId: senderId,
        senderName: senderName,
        messageText: messageText,
        isImage: isImage,
        isFile: isFile,
      );
    } catch (e) {
      appLog('Failed to show notification: $e');
    }
  }

  void _handleMessageSent(Map<String, dynamic> data) {
    final seqId = data['seq_id'];
    if (seqId is! int) return;
    final clientId = data['client_id'] as String?;
    final createdAt = data['created_at'];

    bool matched = false;

    // 1. Точное сопоставление по client_id
    if (clientId != null && clientId.isNotEmpty) {
      for (final messages in _chats.values) {
        for (var i = 0; i < messages.length; i++) {
          if (messages[i].clientId == clientId && messages[i].seqId == 0) {
            messages[i] = messages[i].copyWith(
              seqId: seqId,
              status: 'sent',
              createdAt: createdAt is int ? createdAt : null,
            );
            _db.insertMessage(messages[i]);
            matched = true;
            break;
          }
        }
        if (matched) break;
      }
    }

    // 2. Fallback для старого сервера без client_id: самое старое pending
    if (!matched) {
      Message? oldest;
      List<Message>? oldestList;
      int oldestIndex = -1;
      for (final messages in _chats.values) {
        for (var i = 0; i < messages.length; i++) {
          final m = messages[i];
          if (m.status == 'pending' && m.seqId == 0 &&
              (oldest == null || m.createdAt < oldest.createdAt)) {
            oldest = m;
            oldestList = messages;
            oldestIndex = i;
          }
        }
      }
      if (oldest != null && oldestList != null) {
        oldestList[oldestIndex] = oldest.copyWith(seqId: seqId, status: 'sent');
        _db.insertMessage(oldestList[oldestIndex]);
      }
    }

    notifyListeners();
  }

  Future<void> _handleSyncResponse(Map<String, dynamic> data) async {
    final messagesList = data['messages'] as List? ?? [];
    final direction = (data['direction'] as String?) ??
        'forward'; // старый сервер не присылает direction
    final hasMore = data['has_more'] == true;

    int maxSeqId = 0;

    for (var m in messagesList) {
      if (m is! Map<String, dynamic>) continue;
      final message = Message.fromJson(m);
      if (message.seqId > maxSeqId) maxSeqId = message.seqId;

      final oderId = message.senderId == _myUserId
          ? message.recipientId
          : message.senderId;

      if (message.isDeleted) {
        // Tombstone: сообщение удалили, пока мы были офлайн
        _chats[oderId]?.removeWhere((msg) => msg.seqId == message.seqId);
        _db.deleteMessage(message.seqId);
        continue;
      }

      _chats[oderId] ??= [];

      final exists = _chats[oderId]!.any((msg) => msg.seqId == message.seqId);
      if (!exists) {
        _chats[oderId]!.add(message);
        _db.insertMessage(message);
      }
    }

    for (var oderId in _chats.keys) {
      _chats[oderId]!.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    if (direction == 'forward') {
      if (hasMore && maxSeqId > 0 && _forwardSyncPages < _maxForwardSyncPages) {
        // Сервер отдаёт историю страницами — продолжаем, пока не догоним
        _forwardSyncPages++;
        notifyListeners();
        _ws.sync(sinceSeqId: maxSeqId);
        return;
      }
      _forwardSyncPages = 0;
      _isLoading = false;
    } else {
      // Пагинация назад: меньше страницы — истории больше нет
      if (!hasMore) {
        for (var oderId in _chats.keys) {
          _hasMoreMessages[oderId] = false;
        }
      }
    }

    notifyListeners();
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    final seqId = data['seq_id'];
    final status = data['status'];
    if (seqId is! int || status is! String) return;

    for (var messages in _chats.values) {
      for (var i = 0; i < messages.length; i++) {
        if (messages[i].seqId == seqId) {
          messages[i] = messages[i].copyWith(status: status);
          _db.updateMessageStatus(seqId, status);
          notifyListeners();
          return;
        }
      }
    }
  }

  void _handleMessageDeleted(Map<String, dynamic> data) {
    final seqId = data['seq_id'];
    if (seqId is! int) return;

    for (var messages in _chats.values) {
      messages.removeWhere((m) => m.seqId == seqId);
    }

    _db.deleteMessage(seqId);
    notifyListeners();
  }

  Future<void> _syncMessages() async {
    if (_myUserId == null) return;

    _isLoading = true;
    _forwardSyncPages = 0;
    notifyListeners();

    final lastSeqId = await _db.getLastSeqId();
    appLog('Syncing from seq_id=$lastSeqId');
    _ws.sync(sinceSeqId: lastSeqId);
  }

  Future<void> loadLocalMessages(int oderId) async {
    if (_myUserId == null) return;

    final messages = await _db.getMessages(oderId, _myUserId!);

    if (messages.isNotEmpty) {
      _chats[oderId] = messages;
      notifyListeners();
    }
  }

  /// Проверяет, можно ли сейчас отправлять (Windows без связи — нельзя)
  void _ensureOnline() {
    if (Platform.isWindows && !ConnectionService().isConnected) {
      throw SendMessageException('Сервер недоступен');
    }
  }

  /// Отправить текстовое сообщение.
  ///
  /// Открытый текст НИКОГДА не отправляется: если ключ собеседника недоступен
  /// или шифрование не удалось — бросается [SendMessageException].
  Future<void> sendMessage(int recipientId, String content) async {
    if (_myUserId == null) return;
    _ensureOnline();

    await _ensureUserPublicKey(recipientId);

    if (!_crypto.hasUserPublicKey(recipientId)) {
      throw SendMessageException(
        'Нет ключа шифрования собеседника. Сообщение не отправлено.',
      );
    }

    Uint8List encryptedContent;
    try {
      encryptedContent = await _crypto.encrypt(content, recipientId);
    } catch (e) {
      appLog('Encryption failed: $e');
      throw SendMessageException('Не удалось зашифровать сообщение');
    }

    _enqueueOutgoing(
      recipientId: recipientId,
      encryptedContent: encryptedContent,
      contentType: 'encrypted',
    );
  }

  /// Кладёт исходящее сообщение в чат (status=pending) и отправляет его.
  void _enqueueOutgoing({
    required int recipientId,
    required Uint8List encryptedContent,
    required String contentType,
    String? fileId,
  }) {
    final clientId = const Uuid().v4();

    final tempMessage = Message(
      seqId: 0,
      senderId: _myUserId!,
      recipientId: recipientId,
      encryptedContent: encryptedContent,
      contentType: contentType,
      fileId: fileId,
      createdAt: TimeService().getNow(),
      status: 'pending',
      clientId: clientId,
    );

    _chats[recipientId] ??= [];
    _chats[recipientId]!.insert(0, tempMessage);
    notifyListeners();

    final pending = _PendingSend(
      recipientId: recipientId,
      encryptedContent: encryptedContent,
      contentType: contentType,
      fileId: fileId,
      clientId: clientId,
    );

    if (!_sendPending(pending)) {
      // Нет соединения — отправим при подключении
      _unsentQueue.add(pending);
    }
  }

  bool _sendPending(_PendingSend p) {
    return _ws.sendEncryptedMessage(
      recipientId: p.recipientId,
      encryptedContent: p.encryptedContent,
      contentType: p.contentType,
      fileId: p.fileId,
      clientId: p.clientId,
    );
  }

  void _flushUnsentQueue() {
    if (_unsentQueue.isEmpty) return;
    final queue = List<_PendingSend>.from(_unsentQueue);
    _unsentQueue.clear();
    for (final p in queue) {
      if (!_sendPending(p)) {
        _unsentQueue.add(p);
      }
    }
  }

  Future<void> sendFile({
    required int recipientId,
    required File file,
    required String fileName,
    bool isImage = false,
    void Function(double progress)? onProgress,
  }) async {
    if (_myUserId == null) return;
    _ensureOnline();

    await _ensureUserPublicKey(recipientId);
    if (!_crypto.hasUserPublicKey(recipientId)) {
      throw SendMessageException('Нет ключа шифрования для получателя');
    }

    final fileBytes = await file.readAsBytes();
    final mimeType = lookupMimeType(fileName) ?? 'application/octet-stream';

    Uint8List encryptedFileData;
    final contentType = isImage ? 'encrypted_image' : 'encrypted_file';
    try {
      encryptedFileData = await _crypto.encryptBytes(fileBytes, recipientId);
    } catch (e) {
      appLog('File encryption failed: $e');
      throw SendMessageException('Не удалось зашифровать файл');
    }

    onProgress?.call(0.1);

    final Map<String, dynamic> uploadResult;
    try {
      uploadResult = await _api.uploadFile(
        userId: _myUserId!,
        file: file,
        fileName: fileName,
        encryptedData: encryptedFileData,
        mimeType: mimeType,
        onProgress: (p) => onProgress?.call(0.1 + p * 0.8),
      );
    } on ApiException catch (e) {
      throw SendMessageException(e.userMessage);
    }

    final fileId = uploadResult['file_id'] as String;
    onProgress?.call(0.95);

    // Имя, размер и MIME-тип уходят только в зашифрованном виде
    final metadata = {
      'file_name': fileName,
      'file_size': fileBytes.length,
      'mime_type': mimeType,
      'is_image': isImage,
    };

    final encryptedMetadata = await _crypto.encrypt(
      jsonEncode(metadata),
      recipientId,
    );

    _enqueueOutgoing(
      recipientId: recipientId,
      encryptedContent: encryptedMetadata,
      contentType: contentType,
      fileId: fileId,
    );

    onProgress?.call(1.0);
  }

  Future<Uint8List> downloadFile(Message message) async {
    if (message.fileId == null || message.fileId!.isEmpty) {
      throw Exception('No file ID');
    }

    // Проверка связи на Windows
    if (Platform.isWindows && !ConnectionService().isConnected) {
      throw Exception('Сервер недоступен');
    }

    final encryptedData = await _api.downloadFile(message.fileId!);

    final senderId = message.senderId == _myUserId
        ? message.recipientId
        : message.senderId;

    await _ensureUserPublicKey(senderId);

    if (!_crypto.hasUserPublicKey(senderId)) {
      throw Exception('Нет ключа для расшифровки');
    }

    return _crypto.decryptBytes(encryptedData, senderId);
  }

  Future<Map<String, dynamic>?> getFileMetadata(Message message) async {
    if (!message.isFileMessage) {
      return null;
    }

    try {
      final decrypted = await decryptMessage(message);
      final parsed = jsonDecode(decrypted);
      return parsed is Map<String, dynamic> ? parsed : null;
    } catch (e) {
      appLog('Failed to get file metadata: $e');
      return null;
    }
  }

  Future<String> decryptMessage(Message message) async {
    if (!message.isEncrypted) {
      // Открытый текст: показываем, но явно помечаем
      return '$unencryptedMarker${message.textContent}';
    }

    final senderId = message.senderId == _myUserId
        ? message.recipientId
        : message.senderId;

    await _ensureUserPublicKey(senderId);

    if (!_crypto.hasUserPublicKey(senderId)) {
      return '[Не удалось расшифровать]';
    }

    try {
      return await _crypto.decrypt(message.encryptedContent, senderId);
    } catch (e) {
      appLog('Decryption failed: $e');
      return '[Ошибка расшифровки]';
    }
  }

  void deleteMessage(int seqId) {
    if (Platform.isWindows && !ConnectionService().isConnected) return;
    _ws.deleteMessage(seqId);
  }

  void markAsRead(int seqId) {
    if (Platform.isWindows && !ConnectionService().isConnected) return;
    _ws.markRead(seqId);
  }

  void markChatAsRead(int oderId) {
    if (_myUserId == null) return;
    if (Platform.isWindows && !ConnectionService().isConnected) return;

    final messages = _chats[oderId];
    if (messages == null || messages.isEmpty) return;

    final unreadIncoming = messages
        .where((m) => m.senderId != _myUserId && m.status != 'read' && m.seqId > 0)
        .toList();

    if (unreadIncoming.isEmpty) return;

    int maxSeqId = 0;
    for (final msg in unreadIncoming) {
      if (msg.seqId > maxSeqId) {
        maxSeqId = msg.seqId;
      }
    }

    _ws.markRead(maxSeqId);

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.senderId != _myUserId && msg.status != 'read' && msg.seqId <= maxSeqId) {
        messages[i] = msg.copyWith(status: 'read');
        _db.updateMessageStatus(msg.seqId, 'read');
      }
    }

    notifyListeners();
  }

  int getUnreadCount(int oderId) {
    if (_myUserId == null) return 0;

    final messages = _chats[oderId];
    if (messages == null) return 0;

    return messages
        .where((m) => m.senderId != _myUserId && m.status != 'read')
        .length;
  }

  Future<void> deleteChat(int userId) async {
    _chats.remove(userId);
    _usernames.remove(userId);

    await _db.deleteMessagesForUser(userId);
    notifyListeners();
  }

  void addUser(int userId, String username) {
    _usernames[userId] = username;
    _db.saveUsername(userId, username);
    _ensureUserPublicKey(userId);
    notifyListeners();
  }

  List<int> getChatUserIds() {
    return _chats.keys.toList();
  }

  Future<List<Message>> searchMessages(int oderId, String query) async {
    if (query.isEmpty) return [];

    // На Windows без связи — пустой поиск
    if (Platform.isWindows && !ConnectionService().isConnected) {
      return [];
    }

    final messages = _chats[oderId];
    if (messages == null) return [];

    final pattern = query
        .replaceAll(RegExp(r'[.+^${}()|[\]\\]'), r'\$&')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');

    final regex = RegExp(pattern, caseSensitive: false);

    final results = <Message>[];

    for (final msg in messages) {
      if (msg.isFileMessage) {
        continue;
      }

      String text;
      try {
        text = await decryptMessage(msg);
        if (text.startsWith('[')) continue;
      } catch (e) {
        continue;
      }

      if (regex.hasMatch(text.toLowerCase())) {
        results.add(msg);
      }
    }

    return results;
  }

  void sendTyping(int recipientId) {
    if (Platform.isWindows && !ConnectionService().isConnected) return;
    _ws.sendTyping(recipientId);
  }

  Future<void> loadContactSettings(int userId) async {
    final contact = await _db.getContact(userId);
    if (contact != null) {
      _contactSettings[userId] = contact;
      notifyListeners();
    }
  }

  String getContactName(int userId, String defaultName) {
    final customName = _contactSettings[userId]?['custom_name'] as String?;
    return (customName != null && customName.isNotEmpty) ? customName : defaultName;
  }

  int getContactAvatarColor(int userId) {
    return _contactSettings[userId]?['custom_avatar_color'] as int? ?? Colors.blue.value;
  }

  Future<void> saveContactSettings(int userId, String? customName, int? avatarColor) async {
    await _db.saveContact(userId, customName, avatarColor);
    _contactSettings[userId] = {
      'custom_name': customName,
      'custom_avatar_color': avatarColor,
    };
    notifyListeners();
  }

  Future<void> loadBubbleColors() async {
    final myColor = await _db.getSetting('my_bubble_color');
    final otherColor = await _db.getSetting('other_bubble_color');

    if (myColor != null) _myBubbleColor = int.tryParse(myColor) ?? _myBubbleColor;
    if (otherColor != null) _otherBubbleColor = int.tryParse(otherColor) ?? _otherBubbleColor;

    notifyListeners();
  }

  Future<void> _loadNotificationSettings() async {
    final enabled = await _db.getSetting('notifications_enabled');
    _notificationsEnabled = enabled != 'false';
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    await _db.saveSetting('notifications_enabled', enabled.toString());
    notifyListeners();
  }

  Future<void> setMyBubbleColor(int color) async {
    _myBubbleColor = color;
    await _db.saveSetting('my_bubble_color', color.toString());
    notifyListeners();
  }

  Future<void> setOtherBubbleColor(int color) async {
    _otherBubbleColor = color;
    await _db.saveSetting('other_bubble_color', color.toString());
    notifyListeners();
  }

  bool hasMoreMessages(int oderId) {
    return _hasMoreMessages[oderId] ?? true;
  }

  bool isLoadingMore(int oderId) {
    return _isLoadingMore[oderId] ?? false;
  }

  Future<void> loadMoreMessages(int oderId) async {
    if (_myUserId == null) return;
    if (_isLoadingMore[oderId] == true) return;
    if (_hasMoreMessages[oderId] == false) return;

    // Проверка связи на Windows
    if (Platform.isWindows && !ConnectionService().isConnected) return;

    final messages = _chats[oderId];
    if (messages == null || messages.isEmpty) return;

    final withSeq = messages.where((m) => m.seqId > 0).map((m) => m.seqId);
    if (withSeq.isEmpty) return;

    _isLoadingMore[oderId] = true;
    notifyListeners();

    try {
      final oldestSeqId = withSeq.reduce((a, b) => a < b ? a : b);
      _ws.syncBefore(beforeSeqId: oldestSeqId, limit: 50);
      await Future.delayed(const Duration(seconds: 2));
    } catch (e) {
      appLog('Error loading more messages: $e');
    } finally {
      _isLoadingMore[oderId] = false;
      notifyListeners();
    }
  }

  Future<void> clearLocalData() async {
    _chats.clear();
    _typingUsers.clear();
    _hasMoreMessages.clear();
    _isLoadingMore.clear();
    _unsentQueue.clear();

    final db = await _db.database;
    await db.delete('messages');

    notifyListeners();
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    if (Platform.isWindows) {
      ConnectionService().removeListener(_onConnectionChanged);
    }
    super.dispose();
  }
}
