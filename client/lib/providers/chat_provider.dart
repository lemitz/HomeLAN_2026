// lib/providers/chat_provider.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import '../models/models.dart';
import '../services/services.dart';

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

  void setUserId(int userId) {
    _myUserId = userId;
    print('ChatProvider: setUserId=$userId');
    _loadAllDataFromDB(); 
    _syncMessages();
  }

  Future<void> _loadAllDataFromDB() async {
    if (_myUserId == null) return;
    
    print('📂 Loading all data from local DB...');
    
    final savedUsernames = await _db.getAllUsernames();
    _usernames.addAll(savedUsernames);
    print('📂 Loaded ${savedUsernames.length} usernames');
    
    final savedContacts = await _db.getAllContacts();
    _contactSettings.addAll(savedContacts);
    print('📂 Loaded ${savedContacts.length} contact settings');
    
    final chatUserIds = await _db.getAllChatUserIds(_myUserId!);
    print('📂 Found ${chatUserIds.length} chats in DB');
    
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
        print('🔐 Fetched public key for user $userId');
      }
    } catch (e) {
      print('Failed to fetch public key for user $userId: $e');
    }
  }

  void _listenToWebSocket() {
    _wsSubscription = _ws.messages.listen((message) {
      final type = message['type'];
      final data = message['data'];

      print('WS received: $type');
      
      // Уведомляем ConnectionService о сообщении
      if (Platform.isWindows) {
        ConnectionService().onServerMessage();
      }

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
      }
    });
  }

  Future<void> _handleNewMessage(Map<String, dynamic> data) async {
    final message = Message.fromJson(data);

    final oderId = message.senderId == _myUserId
        ? message.recipientId
        : message.senderId;

    print('New message: seq=${message.seqId} from=${message.senderId} to=${message.recipientId}');

    _chats[oderId] ??= [];

    final exists = _chats[oderId]!.any((m) => m.seqId == message.seqId);
    if (!exists) {
      final messageWithStatus = message.senderId != _myUserId
          ? message.copyWith(status: 'delivered')
          : message;
      
      _chats[oderId]!.insert(0, messageWithStatus);
      _db.insertMessage(messageWithStatus);
      _ws.ack(message.seqId);

      if (message.senderId != _myUserId) {
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
    final userId = data['user_id'] as int;
    _typingUsers[userId] = DateTime.now();
    notifyListeners();
    
    Future.delayed(const Duration(seconds: 3), () {
      if (_typingUsers[userId]?.isBefore(
        DateTime.now().subtract(const Duration(seconds: 3))
      ) ?? false) {
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
      print('Failed to show notification: $e');
    }
  }

  void _handleMessageSent(Map<String, dynamic> data) {
    final seqId = data['seq_id'] as int;
    
    print('Message sent confirmed: seq=$seqId');
    
    for (var oderId in _chats.keys) {
      final messages = _chats[oderId]!;
      for (var i = 0; i < messages.length; i++) {
        if (messages[i].status == 'pending' && messages[i].seqId == 0) {
          final updatedMessage = messages[i].copyWith(
            seqId: seqId,
            status: 'sent',
          );
          messages[i] = updatedMessage;
          _db.insertMessage(updatedMessage);
          print('Updated pending message to seq=$seqId');
          break;
        }
      }
    }
    
    notifyListeners();
  }

  Future<void> _handleSyncResponse(Map<String, dynamic> data) async {
    final messagesList = data['messages'] as List? ?? [];
    
    print('Sync response: ${messagesList.length} messages');
    
    for (var m in messagesList) {
      final message = Message.fromJson(m);
      
      final oderId = message.senderId == _myUserId 
          ? message.recipientId 
          : message.senderId;
      
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
    
    _isLoading = false;

    if (messagesList.length < 50) {
      for (var oderId in _chats.keys) {
        _hasMoreMessages[oderId] = false;
      }
    }

    notifyListeners();
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    final seqId = data['seq_id'] as int;
    final status = data['status'] as String;
    
    print('Status update: seq=$seqId status=$status');
    
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
    final seqId = data['seq_id'] as int;
    
    for (var messages in _chats.values) {
      messages.removeWhere((m) => m.seqId == seqId);
    }
    
    _db.deleteMessage(seqId);
    notifyListeners();
  }

  Future<void> _syncMessages() async {
    if (_myUserId == null) return;
    
    _isLoading = true;
    notifyListeners();
    
    final lastSeqId = await _db.getLastSeqId();
    print('Syncing from seq_id=$lastSeqId');
    _ws.sync(sinceSeqId: lastSeqId);
  }

  Future<void> loadLocalMessages(int oderId) async {
    if (_myUserId == null) {
      print('loadLocalMessages: myUserId is null!');
      return;
    }
    
    print('loadLocalMessages: oderId=$oderId myUserId=$_myUserId');
    
    await _db.printAllMessages();
    
    final messages = await _db.getMessages(oderId, _myUserId!);
    
    print('Loaded ${messages.length} messages from local DB');
    
    if (messages.isNotEmpty) {
      _chats[oderId] = messages;
      notifyListeners();
    }
  }

  Future<void> sendMessage(int recipientId, String content) async {
    if (_myUserId == null) return;
    
    // Проверка связи на Windows
    if (Platform.isWindows && !ConnectionService().isConnected) {
      print('❌ Cannot send: server disconnected');
      return;
    }
    
    await _ensureUserPublicKey(recipientId);
    
    Uint8List encryptedContent;
    
    if (_crypto.hasUserPublicKey(recipientId)) {
      try {
        encryptedContent = await _crypto.encrypt(content, recipientId);
        print('🔐 Message encrypted for user $recipientId');
      } catch (e) {
        print('Encryption failed: $e, sending as plain text');
        encryptedContent = Uint8List.fromList(utf8.encode(content));
      }
    } else {
      print('⚠️ No public key for user $recipientId, sending unencrypted');
      encryptedContent = Uint8List.fromList(utf8.encode(content));
    }
    
    final tempMessage = Message(
      seqId: 0,
      senderId: _myUserId!,
      recipientId: recipientId,
      encryptedContent: encryptedContent,
      contentType: _crypto.hasUserPublicKey(recipientId) ? 'encrypted' : 'text',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'pending',
    );
    
    _chats[recipientId] ??= [];
    _chats[recipientId]!.insert(0, tempMessage);
    notifyListeners();
    
    _ws.sendEncryptedMessage(
      recipientId: recipientId,
      encryptedContent: encryptedContent,
      contentType: tempMessage.contentType,
    );
  }

  Future<void> sendFile({
    required int recipientId,
    required File file,
    required String fileName,
    bool isImage = false,
    void Function(double progress)? onProgress,
  }) async {
    if (_myUserId == null) return;
    
    // Проверка связи на Windows
    if (Platform.isWindows && !ConnectionService().isConnected) {
      print('❌ Cannot send file: server disconnected');
      return;
    }

    print('📎 Sending file: $fileName to user $recipientId');

    await _ensureUserPublicKey(recipientId);

    final fileBytes = await file.readAsBytes();
    final mimeType = lookupMimeType(fileName) ?? 'application/octet-stream';
    
    print('📎 File size: ${fileBytes.length} bytes, mime: $mimeType');

    Uint8List encryptedFileData;
    String contentType;

    if (_crypto.hasUserPublicKey(recipientId)) {
      try {
        encryptedFileData = await _crypto.encryptBytes(fileBytes, recipientId);
        contentType = isImage ? 'encrypted_image' : 'encrypted_file';
        print('🔐 File encrypted: ${encryptedFileData.length} bytes');
      } catch (e) {
        print('File encryption failed: $e');
        throw Exception('Не удалось зашифровать файл');
      }
    } else {
      print('⚠️ No public key, cannot send file securely');
      throw Exception('Нет ключа шифрования для получателя');
    }

    onProgress?.call(0.1);
    
    final uploadResult = await _api.uploadFile(
      userId: _myUserId!,
      file: file,
      fileName: fileName,
      encryptedData: encryptedFileData,
      mimeType: mimeType,
      onProgress: (p) => onProgress?.call(0.1 + p * 0.8),
    );

    final fileId = uploadResult['file_id'] as String;
    print('📎 File uploaded: $fileId');

    onProgress?.call(0.95);

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

    final tempMessage = Message(
      seqId: 0,
      senderId: _myUserId!,
      recipientId: recipientId,
      encryptedContent: encryptedMetadata,
      contentType: contentType,
      fileId: fileId,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'pending',
    );

    _chats[recipientId] ??= [];
    _chats[recipientId]!.insert(0, tempMessage);
    notifyListeners();

    _ws.sendEncryptedMessage(
      recipientId: recipientId,
      encryptedContent: encryptedMetadata,
      contentType: contentType,
      fileId: fileId,
    );

    onProgress?.call(1.0);
    print('📎 File message sent!');
  }

  Future<Uint8List> downloadFile(Message message) async {
    if (message.fileId == null || message.fileId!.isEmpty) {
      throw Exception('No file ID');
    }
    
    // Проверка связи на Windows
    if (Platform.isWindows && !ConnectionService().isConnected) {
      throw Exception('Сервер недоступен');
    }

    print('📥 Downloading file: ${message.fileId}');

    final encryptedData = await _api.downloadFile(message.fileId!);
    
    final senderId = message.senderId == _myUserId 
        ? message.recipientId 
        : message.senderId;

    await _ensureUserPublicKey(senderId);

    if (!_crypto.hasUserPublicKey(senderId)) {
      throw Exception('Нет ключа для расшифровки');
    }

    final decryptedData = await _crypto.decryptBytes(encryptedData, senderId);
    
    print('📥 File decrypted: ${decryptedData.length} bytes');
    return decryptedData;
  }

  Future<Map<String, dynamic>?> getFileMetadata(Message message) async {
    if (!message.contentType.contains('file') && !message.contentType.contains('image')) {
      return null;
    }

    try {
      final decrypted = await decryptMessage(message);
      return jsonDecode(decrypted) as Map<String, dynamic>;
    } catch (e) {
      print('Failed to get file metadata: $e');
      return null;
    }
  }

  Future<String> decryptMessage(Message message) async {
    if (message.contentType != 'encrypted' && 
        !message.contentType.startsWith('encrypted_')) {
      return message.textContent;
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
      print('Decryption failed: $e');
      return '[Ошибка расшифровки]';
    }
  }

  void deleteMessage(int seqId) {
    if (Platform.isWindows && !ConnectionService().isConnected) return;
    _ws.deleteMessage(seqId);
  }

  void markAsRead(int seqId) {
    if (Platform.isWindows && !ConnectionService().isConnected) return;
    print('📖 Marking as read: seq=$seqId');
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
    
    print('📖 Marking chat $oderId as read up to seq=$maxSeqId (${unreadIncoming.length} messages)');
    
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
    
    print('🗑️ Deleted chat with user $userId');
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
      if (msg.contentType.contains('file') || msg.contentType.contains('image')) {
        continue;
      }
      
      String text;
      if (msg.contentType == 'encrypted' || msg.contentType.startsWith('encrypted_')) {
        try {
          text = await decryptMessage(msg);
          if (text.startsWith('[')) continue;
        } catch (e) {
          continue;
        }
      } else {
        text = msg.textContent;
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
    
    if (myColor != null) _myBubbleColor = int.parse(myColor);
    if (otherColor != null) _otherBubbleColor = int.parse(otherColor);
    
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
    
    _isLoadingMore[oderId] = true;
    notifyListeners();
    
    try {
      final oldestSeqId = messages
          .where((m) => m.seqId > 0)
          .map((m) => m.seqId)
          .reduce((a, b) => a < b ? a : b);
      
      print('📜 Loading more messages before seq=$oldestSeqId');
      
      _ws.syncBefore(beforeSeqId: oldestSeqId, limit: 50);
      
      await Future.delayed(const Duration(seconds: 2));
      
    } catch (e) {
      print('Error loading more messages: $e');
    } finally {
      _isLoadingMore[oderId] = false;
      notifyListeners();
    }
  }

  Future<void> clearLocalData() async {
    print('🧹 Clearing local message data...');
    
    _chats.clear();
    _typingUsers.clear();
    _hasMoreMessages.clear();
    _isLoadingMore.clear();
    
    final db = await _db.database;
    await db.delete('messages');
    
    print('🧹 Local messages cleared');
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