// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../theme.dart';
import 'auth_provider.dart';

/// Переписка с собеседником.
///
/// Сервер — источник правды. Клиент хранит кеш шифротекстов и курсор
/// синхронизации (change_seq). После каждого подключения: досинхронизация
/// по курсору (включая удаления и статусы), затем отправка outbox.
/// Расшифрованный текст живёт только в памяти.
class ChatProvider with ChangeNotifier {
  final WebSocketService _ws;
  final DatabaseService _db;
  final ApiService _api;
  final CryptoService _crypto;
  final NotificationService _notifications;
  AuthProvider? _auth;

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
    _wsSub = _ws.messages.listen(_onWsMessage);
    _ws.onConnected = _onConnected;
    _loadSettings();
  }

  StreamSubscription? _wsSub;
  final _uuid = const Uuid();

  int? _myId;
  int? _peerId;

  /// Сообщения, новые первыми.
  List<Message> _messages = [];
  final Map<String, DecryptedContent> _decrypted = {};
  final Set<String> _decrypting = {};

  bool _syncing = false;
  bool _hasMoreHistory = true;
  bool _loadingHistory = false;
  bool _chatVisible = false;
  DateTime? _peerTypingAt;

  int _myBubbleColor = AppColors.myBubble.toARGB32();
  int _otherBubbleColor = AppColors.otherBubble.toARGB32();
  bool _notificationsEnabled = true;
  Map<String, dynamic>? _contact;

  List<Message> get messages => _messages;
  bool get isSyncing => _syncing;
  bool get hasMoreHistory => _hasMoreHistory;
  bool get isLoadingHistory => _loadingHistory;
  int get myBubbleColor => _myBubbleColor;
  int get otherBubbleColor => _otherBubbleColor;
  bool get notificationsEnabled => _notificationsEnabled;
  int? get myUserId => _myId;

  bool get isPeerTyping => _peerTypingAt != null && DateTime.now().difference(_peerTypingAt!).inSeconds < 4;

  DecryptedContent? decryptedOf(Message m) => _decrypted[m.key];

  // ============ ПРОИЗВОДИТЕЛЬНОСТЬ ============

  /// Растёт при каждом изменении списка сообщений. Список в UI подписан
  /// только на него, поэтому расшифровка, «печатает» и т.п. его не перестраивают.
  int _revision = 0;
  int get revision => _revision;

  bool _notifyScheduled = false;
  bool _disposed = false;

  /// Уведомления объединяются: не чаще одного раза за кадр. При синхронизации
  /// сотен сообщений это превращает сотни перестроек UI в одну.
  @override
  void notifyListeners() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) super.notifyListeners();
    });
  }

  void _touch() {
    _revision++;
    notifyListeners();
  }

  /// Новые сообщения внизу чата, которые нужно показать с анимацией.
  final Set<String> _appear = {};

  /// true один раз для только что пришедшего/отправленного сообщения.
  bool takeAppear(String key) => _appear.remove(key);

  int get unreadCount => _messages.where((m) => m.senderId == _peerId && m.readAt == null && !m.isDeleted).length;

  // ============ ЖИЗНЕННЫЙ ЦИКЛ ============

  /// Вызывается из ProxyProvider при изменении авторизации.
  void attachAuth(AuthProvider auth) {
    _auth = auth;
    final me = auth.isLoggedIn ? auth.userId : null;
    final peer = auth.isLoggedIn ? auth.partnerId : null;
    if (me == _myId && peer == _peerId) return;

    if (me == null) {
      _reset();
      return;
    }
    final firstStart = _myId != me;
    _myId = me;
    _peerId = peer;
    if (firstStart) {
      _reset(keepIds: true);
      _loadFromCache();
    } else {
      _decryptAll();
    }
    if (_ws.isConnected) _onConnected();
  }

  void _reset({bool keepIds = false}) {
    if (!keepIds) {
      _myId = null;
      _peerId = null;
    }
    _messages = [];
    _decrypted.clear();
    _decrypting.clear();
    _hasMoreHistory = true;
    _syncing = false;
    _contact = null;
    _touch();
  }

  Future<void> _loadFromCache() async {
    final cached = await _db.recentMessages(limit: 200);
    if (_myId == null) return;
    _messages = cached;
    if (_peerId != null) _contact = await _db.getContact(_peerId!);
    _touch();
    _decryptAll();
  }

  /// Видимость экрана чата (для отметок «прочитано» и уведомлений).
  void setChatVisible(bool visible) {
    _chatVisible = visible;
    if (visible) {
      if (_peerId != null) _notifications.cancelNotificationsFromUser(_peerId!);
      markRead();
    }
  }

  void _onConnected() {
    if (_myId == null) return;
    _sync();
  }

  // ============ СИНХРОНИЗАЦИЯ ============

  Future<void> _sync() async {
    if (_syncing) return;
    _syncing = true;
    _touch();
    final cursor = await _db.getSyncCursor();
    if (!_ws.send('sync', {'since': cursor, 'limit': 200})) {
      _syncing = false;
      _touch();
    }
  }

  Future<void> _onSyncResponse(Map<String, dynamic> data) async {
    final list = (data['messages'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final json in list) {
      await _applyServerMessage(Message.fromServer(json), fromSync: true);
    }
    final cursor = data['cursor'] as int? ?? 0;
    if (cursor > 0) await _db.setSyncCursor(cursor);

    if (data['has_more'] == true) {
      _ws.send('sync', {'since': cursor, 'limit': 200});
      return;
    }
    _syncing = false;
    _touch();
    await _flushOutbox();
    _ackUndelivered();
    if (_chatVisible) markRead();
  }

  Future<void> _applyServerMessage(Message incoming, {bool fromSync = false}) async {
    if (_myId == null) return;
    final stored = await _db.upsertServerMessage(incoming);
    final idx = _messages.indexWhere((m) => m.key == stored.key);
    final isNew = idx < 0;

    if (stored.isDeleted) {
      if (!isNew) _messages.removeAt(idx);
      _decrypted.remove(stored.key);
      _touch();
      return;
    }

    if (isNew) {
      final at = _insertIndex(stored);
      if (at == 0 && _messages.isNotEmpty) _appear.add(stored.key);
      _messages.insert(at, stored);
    } else {
      _messages[idx] = stored;
    }
    _touch();
    await _decrypt(stored);

    final incomingFromPeer = stored.senderId != _myId;
    if (incomingFromPeer && stored.deliveredAt == null && !fromSync) {
      _ws.send('ack', {'seq_id': stored.seqId});
    }
    if (incomingFromPeer && isNew && !fromSync) {
      _peerTypingAt = null;
      if (_chatVisible) {
        markRead();
      } else {
        _notify(stored);
      }
    }
  }

  int _insertIndex(Message m) {
    for (var i = 0; i < _messages.length; i++) {
      final other = _messages[i];
      if (other.createdAt < m.createdAt ||
          (other.createdAt == m.createdAt && (other.seqId ?? 1 << 62) < (m.seqId ?? 1 << 62))) {
        return i;
      }
    }
    return _messages.length;
  }

  void _ackUndelivered() {
    for (final m in _messages) {
      if (m.senderId != _myId && m.deliveredAt == null && m.seqId != null) {
        _ws.send('ack', {'seq_id': m.seqId});
      }
    }
  }

  /// Отмечает прочитанными все входящие сообщения.
  void markRead() {
    if (_myId == null) return;
    int maxSeq = 0;
    for (final m in _messages) {
      if (m.senderId != _myId && m.readAt == null && (m.seqId ?? 0) > maxSeq) maxSeq = m.seqId!;
    }
    if (maxSeq > 0) _ws.send('read', {'up_to_seq': maxSeq});
  }

  /// Загрузка более старых сообщений: сначала из кеша, потом с сервера.
  Future<void> loadOlder() async {
    if (_loadingHistory || !_hasMoreHistory || _messages.isEmpty) return;
    _loadingHistory = true;
    _touch();
    final oldest = _messages.last;
    final cached = await _db.recentMessages(limit: 100, beforeCreatedAt: oldest.createdAt);
    final known = _messages.map((m) => m.key).toSet();
    final fresh = cached.where((m) => !known.contains(m.key)).toList();
    if (fresh.isNotEmpty) {
      _messages.addAll(fresh);
      _loadingHistory = false;
      _touch();
      _decryptAll();
      return;
    }
    final oldestSeq = _messages
        .where((m) => m.seqId != null)
        .map((m) => m.seqId!)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (oldestSeq == null || !_ws.send('history', {'before_seq': oldestSeq, 'limit': 50})) {
      _loadingHistory = false;
      _touch();
    }
  }

  Future<void> _onHistoryResponse(Map<String, dynamic> data) async {
    final list = (data['messages'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final json in list) {
      final m = Message.fromServer(json);
      final stored = await _db.upsertServerMessage(m);
      if (!_messages.any((x) => x.key == stored.key) && !stored.isDeleted) {
        _messages.insert(_insertIndex(stored), stored);
      }
    }
    _hasMoreHistory = data['has_more'] == true;
    _loadingHistory = false;
    _touch();
    _decryptAll();
  }

  // ============ WEBSOCKET ============

  void _onWsMessage(Map<String, dynamic> msg) {
    final data = msg['data'];
    if (data is! Map<String, dynamic>) return;
    switch (msg['type']) {
      case 'message':
        _applyServerMessage(Message.fromServer(data));
        break;
      case 'message_sent':
        _onMessageSent(data);
        break;
      case 'send_failed':
        _onSendFailed(data);
        break;
      case 'sync_response':
        _onSyncResponse(data);
        break;
      case 'history_response':
        _onHistoryResponse(data);
        break;
      case 'typing':
        if (data['user_id'] == _peerId) {
          _peerTypingAt = DateTime.now();
          notifyListeners();
          Future.delayed(const Duration(seconds: 4), notifyListeners);
        }
        break;
    }
  }

  void _onMessageSent(Map<String, dynamic> data) {
    // Полное состояние приходит отдельным событием "message";
    // здесь только снимаем pending-статус на случай, если оно задержится.
    final clientId = data['client_id'] as String?;
    final idx = _messages.indexWhere((m) => m.senderId == _myId && m.clientId == clientId);
    if (idx >= 0 && _messages[idx].localStatus != LocalStatus.sent) {
      _messages[idx] = _messages[idx].copyWith(localStatus: LocalStatus.sent);
      _touch();
    }
  }

  Future<void> _onSendFailed(Map<String, dynamic> data) async {
    final clientId = data['client_id'] as String?;
    final idx = _messages.indexWhere((m) => m.senderId == _myId && m.clientId == clientId);
    if (idx < 0) return;
    final m = _messages[idx];
    final reason = data['message'] as String? ?? data['code'] as String?;
    _messages[idx] = m.copyWith(localStatus: LocalStatus.failed, failReason: reason);
    if (m.localId != null) await _db.setLocalStatus(m.localId!, LocalStatus.failed, reason: reason);
    _touch();
  }

  // ============ ОТПРАВКА ============

  void _requireKey() {
    if (_myId == null || _peerId == null) throw StateError(S.current.noPartnerYet);
    final status = _crypto.peerStatus(_peerId!);
    if (status == PeerKeyStatus.mismatch) {
      throw CryptoException(S.current.peerKeyChanged);
    }
    if (status == PeerKeyStatus.unknown) throw CryptoException(S.current.noPeerKey);
  }

  Future<void> sendText(String text) async {
    _requireKey();
    await _enqueue(contentType: 'text', plaintext: Uint8List.fromList(utf8.encode(text)));
  }

  Future<void> _enqueue({required String contentType, required Uint8List plaintext, String? fileId}) async {
    final clientId = _uuid.v4();
    final encrypted = await _crypto.encryptMessage(
      plaintext: plaintext,
      myId: _myId!,
      peerId: _peerId!,
      contentType: contentType,
      clientId: clientId,
    );
    var msg = Message(
      clientId: clientId,
      senderId: _myId!,
      recipientId: _peerId!,
      contentType: contentType,
      encryptedContent: encrypted,
      fileId: fileId,
      createdAt: TimeService().getNow(),
      localStatus: LocalStatus.pending,
    );
    msg = await _db.insertPending(msg);
    _appear.add(msg.key);
    _messages.insert(0, msg);
    _decrypted[msg.key] = contentType == 'text'
        ? DecryptedContent.text(utf8.decode(plaintext))
        : DecryptedContent.file(FileMeta.fromJson(jsonDecode(utf8.decode(plaintext))));
    _touch();
    _transmit(msg);
  }

  void _transmit(Message m) {
    _ws.send('send_message', {
      'client_id': m.clientId,
      'recipient_id': m.recipientId,
      'content_type': m.contentType,
      'encrypted_content': base64Encode(m.encryptedContent),
      if (m.fileId != null) 'file_id': m.fileId,
      if (m.expiresAt != null) 'expires_at': m.expiresAt,
    });
  }

  /// Отправляет все неотправленные сообщения (сервер дедуплицирует по client_id).
  Future<void> _flushOutbox() async {
    if (_myId == null) return;
    for (final m in await _db.pendingMessages(_myId!)) {
      _transmit(m);
    }
  }

  /// Повторная отправка сообщения с ошибкой.
  Future<void> retry(Message m) async {
    if (m.localId == null) return;
    await _db.setLocalStatus(m.localId!, LocalStatus.pending);
    final idx = _messages.indexWhere((x) => x.key == m.key);
    final updated = m.copyWith(localStatus: LocalStatus.pending);
    if (idx >= 0) _messages[idx] = updated;
    _touch();
    _transmit(updated);
  }

  /// Удаляет неотправленное сообщение локально.
  Future<void> discard(Message m) async {
    if (m.seqId != null || m.localId == null) return;
    await _db.deleteLocal(m.localId!);
    _messages.removeWhere((x) => x.key == m.key);
    _decrypted.remove(m.key);
    _touch();
  }

  /// Шифрует файл потоком, загружает и отправляет сообщение с метаданными.
  Future<void> sendFile(File file, {bool isImage = false, void Function(double)? onProgress}) async {
    _requireKey();
    final name = p.basename(file.path);
    final size = await file.length();
    final key = FileCipher.newKey();
    final tmpDir = await getTemporaryDirectory();
    final encPath = p.join(tmpDir.path, 'upload_${_uuid.v4()}.hlf');
    try {
      onProgress?.call(0);
      await FileCipher.encrypt(file.path, encPath, key);
      final fileId = await _api.uploadFile(encPath, onProgress: (v) => onProgress?.call(v));
      final meta = FileMeta(name: name, size: size, mime: lookupMimeType(name) ?? 'application/octet-stream', key: key);
      await _enqueue(
        contentType: isImage ? 'image' : 'file',
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson()))),
        fileId: fileId,
      );
    } finally {
      final f = File(encPath);
      if (await f.exists()) await f.delete();
    }
  }

  /// Скачивает и расшифровывает файл во временную папку приложения.
  /// Возвращает путь к расшифрованному файлу.
  Future<String> downloadFile(Message m, {void Function(double)? onProgress}) async {
    final meta = _decrypted[m.key]?.file;
    if (meta == null || m.fileId == null) throw StateError(S.current.noFileData);
    final dir = await decryptedFilesDir();
    final out = p.join(dir.path, '${m.seqId ?? m.clientId}_${safeFileName(meta.name)}');
    if (await File(out).exists()) return out;

    final encPath = '$out.download';
    try {
      await _api.downloadFile(m.fileId!, encPath, onProgress: onProgress);
      await FileCipher.decrypt(encPath, out, meta.key);
    } finally {
      final f = File(encPath);
      if (await f.exists()) await f.delete();
    }
    return out;
  }

  /// Папка расшифрованных файлов. Очищается при запуске и выходе.
  static Future<Directory> decryptedFilesDir() async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'homelan_files'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> clearDecryptedFiles() async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'homelan_files'));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Имя файла без путей и опасных символов.
  static String safeFileName(String name) {
    var base = p.basename(name.replaceAll('\\', '/'));
    base = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    if (base.isEmpty || base == '.' || base == '..') base = 'file';
    return base.length > 120 ? base.substring(base.length - 120) : base;
  }

  void deleteMessage(Message m) {
    if (m.seqId == null) {
      discard(m);
      return;
    }
    _ws.send('delete', {'seq_id': m.seqId});
  }

  DateTime? _lastTypingSent;
  void sendTyping() {
    if (_peerId == null) return;
    final now = DateTime.now();
    if (_lastTypingSent != null && now.difference(_lastTypingSent!).inSeconds < 3) return;
    _lastTypingSent = now;
    _ws.send('typing', {'recipient_id': _peerId});
  }

  // ============ РАСШИФРОВКА ============

  void _decryptAll() {
    for (final m in _messages) {
      _decrypt(m);
    }
  }

  Future<void> _decrypt(Message m) async {
    if (_myId == null || _peerId == null) return;
    final existing = _decrypted[m.key];
    if ((existing != null && !existing.isError) || _decrypting.contains(m.key)) return;
    _decrypting.add(m.key);
    try {
      final clear = await _crypto.decryptMessage(
        blob: m.encryptedContent,
        myId: _myId!,
        peerId: _peerId!,
        senderId: m.senderId,
        recipientId: m.recipientId,
        contentType: m.contentType,
        clientId: m.clientId,
      );
      final text = utf8.decode(clear);
      _decrypted[m.key] = m.isFile
          ? DecryptedContent.file(FileMeta.fromJson(jsonDecode(text) as Map<String, dynamic>))
          : DecryptedContent.text(text);
    } catch (e) {
      _decrypted[m.key] = DecryptedContent.error(e is CryptoException ? e.message : S.current.cantDecrypt);
    } finally {
      _decrypting.remove(m.key);
    }
    notifyListeners();
  }

  Future<void> _notify(Message m) async {
    if (!_notificationsEnabled || _peerId == null) return;
    final d = _decrypted[m.key];
    final name = contactName(_auth?.partnerUsername ?? S.current.contact);
    await _notifications.showMessageNotification(
      senderId: m.senderId,
      senderName: name,
      messageText: d?.text ?? S.current.newMessage,
      isImage: m.isImage,
      isFile: m.contentType == 'file',
    );
  }

  // ============ ПОИСК ============

  /// Поиск по расшифрованному тексту (поддерживается * и ?).
  List<Message> search(String query) {
    if (query.trim().isEmpty) return [];
    final pattern = RegExp.escape(query.trim()).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    final re = RegExp(pattern, caseSensitive: false);
    return _messages.where((m) {
      final d = _decrypted[m.key];
      final text = d?.text ?? d?.file?.name;
      return text != null && re.hasMatch(text);
    }).toList();
  }

  // ============ НАСТРОЙКИ ============

  Future<void> _loadSettings() async {
    final my = await _db.getSetting('my_bubble_color');
    final other = await _db.getSetting('other_bubble_color');
    final notif = await _db.getSetting('notifications_enabled');
    if (my != null) _myBubbleColor = int.tryParse(my) ?? _myBubbleColor;
    if (other != null) _otherBubbleColor = int.tryParse(other) ?? _otherBubbleColor;
    _notificationsEnabled = notif != 'false';
    _touch();
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    await _db.saveSetting('notifications_enabled', enabled.toString());
    _touch();
  }

  Future<void> setMyBubbleColor(int color) async {
    _myBubbleColor = color;
    await _db.saveSetting('my_bubble_color', color.toString());
    _touch();
  }

  Future<void> setOtherBubbleColor(int color) async {
    _otherBubbleColor = color;
    await _db.saveSetting('other_bubble_color', color.toString());
    _touch();
  }

  String contactName(String fallback) {
    final custom = _contact?['custom_name'] as String?;
    return custom != null && custom.isNotEmpty ? custom : fallback;
  }

  int get contactAvatarColor => _contact?['custom_avatar_color'] as int? ?? AppColors.avatarPalette.first.toARGB32();

  Future<void> saveContact(String? name, int? color) async {
    if (_peerId == null) return;
    await _db.saveContact(_peerId!, name, color);
    _contact = {'custom_name': name, 'custom_avatar_color': color};
    _touch();
  }

  @override
  void dispose() {
    _disposed = true;
    _wsSub?.cancel();
    super.dispose();
  }
}
