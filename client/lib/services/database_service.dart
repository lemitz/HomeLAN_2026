// lib/services/database_service.dart
//
// Локальный кеш клиента. Источник правды — сервер: всё, что здесь лежит,
// можно восстановить синхронизацией. Содержимое сообщений хранится только
// в зашифрованном (E2E) виде; расшифрованный текст на диск не пишется.
import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';

class DatabaseService {
  static const _version = 4;
  Future<Database>? _db;

  // Кешируется сам Future: параллельные первые обращения не открывают БД дважды.
  Future<Database> get database => _db ??= _open();

  Future<Database> _open() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationSupportDirectory();
    final path = join(dir.path, 'homelan_cache.db');
    return openDatabase(path, version: _version, onCreate: _create, onUpgrade: _upgrade);
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        local_id          INTEGER PRIMARY KEY AUTOINCREMENT,
        client_id         TEXT NOT NULL,
        seq_id            INTEGER UNIQUE,
        change_seq        INTEGER NOT NULL DEFAULT 0,
        sender_id         INTEGER NOT NULL,
        recipient_id      INTEGER NOT NULL,
        content_type      TEXT NOT NULL,
        encrypted_content BLOB NOT NULL,
        file_id           TEXT,
        created_at        INTEGER NOT NULL,
        expires_at        INTEGER,
        delivered_at      INTEGER,
        read_at           INTEGER,
        is_deleted        INTEGER NOT NULL DEFAULT 0,
        local_status      TEXT NOT NULL DEFAULT 'sent',
        fail_reason       TEXT,
        UNIQUE(sender_id, client_id)
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_created ON messages(created_at)');
    await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
    await db.execute('''
      CREATE TABLE contacts (
        user_id INTEGER PRIMARY KEY,
        custom_name TEXT,
        custom_avatar_color INTEGER
      )
    ''');
  }

  /// Старые версии кеша несовместимы с протоколом v2 — пересоздаём.
  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    for (final t in ['messages', 'users', 'settings', 'contacts']) {
      await db.execute('DROP TABLE IF EXISTS $t');
    }
    await _create(db, newVersion);
  }

  // ============ MESSAGES ============

  /// Сохраняет сообщение от сервера (новое или изменённое).
  /// Совпадение ищется по (sender_id, client_id), поэтому подтверждённое
  /// сервером сообщение заменяет локальное pending.
  Future<Message> upsertServerMessage(Message m) async {
    final db = await database;
    return db.transaction((txn) async {
      final existing = await txn.query('messages',
          columns: ['local_id', 'change_seq'],
          where: 'sender_id = ? AND client_id = ?',
          whereArgs: [m.senderId, m.clientId],
          limit: 1);
      if (existing.isEmpty) {
        final id = await txn.insert('messages', m.toDb());
        return m.copyWith(localId: id);
      }
      final localId = existing.first['local_id'] as int;
      final storedChange = existing.first['change_seq'] as int? ?? 0;
      if (storedChange > m.changeSeq && m.changeSeq != 0) {
        // У нас уже более свежая версия.
        final row = await txn.query('messages', where: 'local_id = ?', whereArgs: [localId]);
        return Message.fromDb(row.first);
      }
      await txn.update('messages', m.toDb(), where: 'local_id = ?', whereArgs: [localId]);
      return m.copyWith(localId: localId);
    });
  }

  Future<Message> insertPending(Message m) async {
    final db = await database;
    final id = await db.insert('messages', m.toDb());
    return m.copyWith(localId: id);
  }

  Future<void> setLocalStatus(int localId, LocalStatus status, {String? reason}) async {
    final db = await database;
    await db.update('messages', {'local_status': status.name, 'fail_reason': reason},
        where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> deleteLocal(int localId) async {
    final db = await database;
    await db.delete('messages', where: 'local_id = ?', whereArgs: [localId]);
  }

  /// Последние сообщения переписки (новые первыми), без удалённых.
  Future<List<Message>> recentMessages({int limit = 200, int? beforeCreatedAt}) async {
    final db = await database;
    final rows = await db.query('messages',
        where: beforeCreatedAt == null ? 'is_deleted = 0' : 'is_deleted = 0 AND created_at < ?',
        whereArgs: beforeCreatedAt == null ? null : [beforeCreatedAt],
        orderBy: 'created_at DESC, local_id DESC',
        limit: limit);
    return rows.map(Message.fromDb).toList();
  }

  /// Неотправленные сообщения (outbox), старые первыми.
  Future<List<Message>> pendingMessages(int myUserId) async {
    final db = await database;
    final rows = await db.query('messages',
        where: "sender_id = ? AND seq_id IS NULL AND local_status = 'pending'",
        whereArgs: [myUserId],
        orderBy: 'local_id ASC');
    return rows.map(Message.fromDb).toList();
  }

  Future<void> clearMessages() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('settings', where: "key = 'sync_cursor'");
  }

  // ============ SETTINGS ============

  Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<int> getSyncCursor() async => int.tryParse(await getSetting('sync_cursor') ?? '') ?? 0;

  Future<void> setSyncCursor(int cursor) => saveSetting('sync_cursor', cursor.toString());

  // ============ CONTACTS ============

  Future<void> saveContact(int userId, String? customName, int? avatarColor) async {
    final db = await database;
    await db.insert(
      'contacts',
      {'user_id': userId, 'custom_name': customName, 'custom_avatar_color': avatarColor},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getContact(int userId) async {
    final db = await database;
    final rows = await db.query('contacts', where: 'user_id = ?', whereArgs: [userId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Полная очистка кеша (сообщения, настройки, контакты).
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('settings');
    await db.delete('contacts');
  }
}
