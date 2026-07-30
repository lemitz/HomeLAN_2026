import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/models.dart';

class DatabaseService {
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, 'homelan_client.db');

    print('Database path: $path');

    return await openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seq_id INTEGER UNIQUE,
        sender_id INTEGER NOT NULL,
        recipient_id INTEGER NOT NULL,
        encrypted_content BLOB NOT NULL,
        content_type TEXT NOT NULL,
        file_id TEXT,
        created_at INTEGER NOT NULL,
        expires_at INTEGER,
        is_deleted INTEGER DEFAULT 0,
        status TEXT DEFAULT 'sent'
      )
    ''');

    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        username TEXT NOT NULL,
        is_admin INTEGER DEFAULT 0,
        created_at INTEGER,
        last_seen INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        user_id INTEGER PRIMARY KEY,
        custom_name TEXT,
        custom_avatar_color INTEGER
      )
    ''');

    await db.execute('CREATE INDEX idx_messages_seq ON messages(seq_id)');
    await db.execute('CREATE INDEX idx_messages_sender ON messages(sender_id)');
    await db.execute('CREATE INDEX idx_messages_recipient ON messages(recipient_id)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('DROP TABLE IF EXISTS messages');
      await db.execute('DROP TABLE IF EXISTS users');
      await db.execute('DROP TABLE IF EXISTS settings');
      await _onCreate(db, newVersion);
    }
    
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS contacts (
          user_id INTEGER PRIMARY KEY,
          custom_name TEXT,
          custom_avatar_color INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT
        )
      ''');
    }
  }

  Future<int> insertMessage(Message message) async {
    final db = await database;
    
    try {
      final result = await db.insert(
        'messages',
        {
          'seq_id': message.seqId,
          'sender_id': message.senderId,
          'recipient_id': message.recipientId,
          'encrypted_content': message.encryptedContent,
          'content_type': message.contentType,
          'file_id': message.fileId,
          'created_at': message.createdAt,
          'expires_at': message.expiresAt,
          'is_deleted': message.isDeleted ? 1 : 0,
          'status': message.status,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      print('Inserted message seq_id=${message.seqId} sender=${message.senderId} recipient=${message.recipientId}');
      return result;
    } catch (e) {
      print('Error inserting message: $e');
      return -1;
    }
  }

  Future<List<Message>> getMessages(int oderId, int myId, {int limit = 50}) async {
    final db = await database;
    
    print('Loading messages: oderId=$oderId myId=$myId');
    
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: '((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)) AND is_deleted = 0',
      whereArgs: [myId, oderId, oderId, myId],
      orderBy: 'created_at DESC',
      limit: limit,
    );

    print('Found ${maps.length} messages in local DB');

    return List.generate(maps.length, (i) {
      final map = maps[i];
      
      Uint8List content;
      if (map['encrypted_content'] is Uint8List) {
        content = map['encrypted_content'];
      } else if (map['encrypted_content'] is List) {
        content = Uint8List.fromList(List<int>.from(map['encrypted_content']));
      } else {
        content = Uint8List(0);
      }
      
      return Message(
        id: map['id'],
        seqId: map['seq_id'] ?? 0,
        senderId: map['sender_id'],
        recipientId: map['recipient_id'],
        encryptedContent: content,
        contentType: map['content_type'] ?? 'text',
        fileId: map['file_id'],
        createdAt: map['created_at'],
        expiresAt: map['expires_at'],
        isDeleted: map['is_deleted'] == 1,
        status: map['status'] ?? 'sent',
      );
    });
  }

  Future<int> getLastSeqId() async {
    final db = await database;
    final result = await db.rawQuery('SELECT MAX(seq_id) as max_seq FROM messages');
    final maxSeq = result.first['max_seq'] as int? ?? 0;
    print('Last seq_id in local DB: $maxSeq');
    return maxSeq;
  }

  Future<void> updateMessageStatus(int seqId, String status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status},
      where: 'seq_id = ?',
      whereArgs: [seqId],
    );
  }

  Future<void> deleteMessage(int seqId) async {
    final db = await database;
    await db.update(
      'messages',
      {'is_deleted': 1},
      where: 'seq_id = ?',
      whereArgs: [seqId],
    );
  }

  Future<void> deleteMessagesForUser(int oderId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'sender_id = ? OR recipient_id = ?',
      whereArgs: [oderId, oderId],
    );
    print('🗑️ Deleted all messages for user $oderId from local DB');
  }

  // НОВЫЙ МЕТОД: Получить всех юзеров с которыми есть переписка
  Future<List<int>> getAllChatUserIds(int myUserId) async {
    final db = await database;
    
    final result = await db.rawQuery('''
      SELECT DISTINCT 
        CASE 
          WHEN sender_id = ? THEN recipient_id 
          ELSE sender_id 
        END as other_id
      FROM messages
      WHERE (sender_id = ? OR recipient_id = ?) AND is_deleted = 0
    ''', [myUserId, myUserId, myUserId]);
    
    return result.map((row) => row['other_id'] as int).toList();
  }

  // НОВЫЙ МЕТОД: Загрузить все контакты
  Future<Map<int, Map<String, dynamic>>> getAllContacts() async {
    final db = await database;
    final result = await db.query('contacts');
    
    final Map<int, Map<String, dynamic>> contacts = {};
    for (final row in result) {
      final userId = row['user_id'] as int;
      contacts[userId] = row;
    }
    return contacts;
  }

  Future<void> insertUser(User user) async {
    final db = await database;
    await db.insert(
      'users',
      user.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<User?> getUser(int id) async {
    final db = await database;
    final maps = await db.query('users', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return User.fromJson(maps.first);
  }

  Future<List<User>> getAllUsers() async {
    final db = await database;
    final maps = await db.query('users');
    return maps.map((m) => User.fromJson(m)).toList();
  }

  Future<void> saveContact(int userId, String? customName, int? avatarColor) async {
    final db = await database;
    await db.insert(
      'contacts',
      {
        'user_id': userId,
        'custom_name': customName,
        'custom_avatar_color': avatarColor,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getContact(int userId) async {
    final db = await database;
    final result = await db.query(
      'contacts',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    return result.isNotEmpty ? result.first : null;
  }

  Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final result = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return result.isNotEmpty ? result.first['value'] as String? : null;
  }

  // НОВЫЙ МЕТОД: Сохранить username в настройках
  Future<void> saveUsername(int userId, String username) async {
    await saveSetting('username_$userId', username);
  }

  // НОВЫЙ МЕТОД: Получить username из настроек
  Future<String?> getUsername(int userId) async {
    return await getSetting('username_$userId');
  }

  // НОВЫЙ МЕТОД: Получить все сохранённые usernames
  Future<Map<int, String>> getAllUsernames() async {
    final db = await database;
    final result = await db.query(
      'settings',
      where: 'key LIKE ?',
      whereArgs: ['username_%'],
    );
    
    final Map<int, String> usernames = {};
    for (final row in result) {
      final key = row['key'] as String;
      final userId = int.tryParse(key.replaceFirst('username_', ''));
      if (userId != null) {
        usernames[userId] = row['value'] as String;
      }
    }
    return usernames;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('users');
    await db.delete('settings');
    await db.delete('contacts');
  }
  
  Future<void> printAllMessages() async {
    final db = await database;
    final maps = await db.query('messages');
    print('=== All messages in DB (${maps.length}) ===');
    for (var m in maps) {
      print('seq=${m['seq_id']} from=${m['sender_id']} to=${m['recipient_id']} deleted=${m['is_deleted']}');
    }
    print('=== End ===');
  }
}