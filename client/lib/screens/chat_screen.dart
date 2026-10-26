// lib/screens/chat_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/services.dart';
import '../widgets/widgets.dart';
import 'devices_screen.dart';
import 'safety_number_screen.dart';
import 'settings_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _search = TextEditingController();
  final _imagePicker = ImagePicker();
  late final ChatProvider _chat;

  bool _searching = false;
  List<Message> _results = [];
  bool _uploading = false;
  double _uploadProgress = 0;
  String? _uploadName;
  bool _showScrollDown = false;

  @override
  void initState() {
    super.initState();
    _chat = context.read<ChatProvider>();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _chat.setChatVisible(true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.setChatVisible(false);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // «Прочитано» отмечаем только когда чат реально на экране.
    _chat.setChatVisible(state == AppLifecycleState.resumed);
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.offset > 200;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
    if (_scroll.hasClients && _scroll.offset >= _scroll.position.maxScrollExtent - 200) {
      _chat.loadOlder();
    }
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red[700]));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    try {
      await _chat.sendText(text);
      _input.clear();
      _scrollToBottom();
    } catch (e) {
      _showError(e.toString());
    }
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ============ ФАЙЛЫ ============

  Future<void> _pickImage(ImageSource source) async {
    try {
      final image = await BiometricService().withoutLock(
        () => _imagePicker.pickImage(source: source, maxWidth: 2560, maxHeight: 2560, imageQuality: 85),
      );
      // На мобильных пикер отдаёт копию в кеше приложения — её удаляем.
      // На ПК это оригинальный файл пользователя — его не трогаем.
      if (image != null) {
        await _upload(File(image.path), isImage: true, temporary: Platform.isAndroid || Platform.isIOS);
      }
    } catch (e) {
      _showError('Не удалось выбрать изображение: $e');
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await BiometricService().withoutLock(() => FilePicker.platform.pickFiles());
      final path = result?.files.single.path;
      if (path != null) await _upload(File(path), temporary: Platform.isAndroid || Platform.isIOS);
    } catch (e) {
      _showError('Не удалось выбрать файл: $e');
    }
  }

  Future<void> _upload(File file, {bool isImage = false, bool temporary = false}) async {
    if (!mounted) return;
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _uploadName = file.uri.pathSegments.last;
    });
    try {
      await _chat.sendFile(file, isImage: isImage, onProgress: (p) {
        if (mounted) setState(() => _uploadProgress = p);
      });
      _scrollToBottom();
    } catch (e) {
      _showError('Ошибка отправки: $e');
    } finally {
      // Копии, созданные пикерами, не храним.
      if (temporary) {
        file.delete().catchError((_) => file);
        if (Platform.isAndroid || Platform.isIOS) FilePicker.platform.clearTemporaryFiles();
      }
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image),
            title: const Text('Фото из галереи'),
            onTap: () {
              Navigator.pop(ctx);
              _pickImage(ImageSource.gallery);
            },
          ),
          if (Platform.isAndroid || Platform.isIOS)
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Сделать фото'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: const Text('Файл'),
            onTap: () {
              Navigator.pop(ctx);
              _pickFile();
            },
          ),
        ]),
      ),
    );
  }

  // ============ МЕНЮ ============

  void _showMessageOptions(Message m, bool isMe) {
    final d = _chat.decryptedOf(m);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (d?.text != null)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Копировать'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: d!.text!));
                Navigator.pop(ctx);
              },
            ),
          if (isMe && m.localStatus == LocalStatus.failed)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Отправить снова'),
              onTap: () {
                Navigator.pop(ctx);
                _chat.retry(m);
              },
            ),
          if (isMe)
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text(m.seqId == null ? 'Удалить (не отправлено)' : 'Удалить у всех',
                  style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _chat.deleteMessage(m);
              },
            ),
        ]),
      ),
    );
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Редактировать контакт'),
            onTap: () {
              Navigator.pop(ctx);
              _editContact();
            },
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Отпечаток ключей'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SafetyNumberScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.devices),
            title: const Text('Мои устройства'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const DevicesScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Настройки'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        ]),
      ),
    );
  }

  void _editContact() {
    final auth = context.read<AuthProvider>();
    final controller = TextEditingController(text: _chat.contactName(auth.partnerUsername ?? ''));
    var color = _chat.contactAvatarColor;
    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.purple,
      Colors.orange,
      Colors.teal,
      Colors.pink,
      Colors.indigo
    ];
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Редактировать контакт'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: controller, decoration: const InputDecoration(labelText: 'Имя')),
            const SizedBox(height: 20),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final c in colors)
                GestureDetector(
                  onTap: () => setD(() => color = c.toARGB32()),
                  child: CircleAvatar(
                    backgroundColor: c,
                    radius: 20,
                    child: color == c.toARGB32() ? const Icon(Icons.check, color: Colors.white) : null,
                  ),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            ElevatedButton(
              onPressed: () {
                _chat.saveContact(controller.text.trim(), color);
                Navigator.pop(ctx);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  // ============ BUILD ============

  String _dateLabel(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    bool same(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
    if (same(d, now)) return 'Сегодня';
    if (same(d, yesterday)) return 'Вчера';
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря'
    ];
    return d.year == now.year ? '${d.day} ${months[d.month - 1]}' : '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  bool _newDay(List<Message> list, int i) {
    if (i == list.length - 1) return true;
    final a = DateTime.fromMillisecondsSinceEpoch(list[i].createdAt * 1000);
    final b = DateTime.fromMillisecondsSinceEpoch(list[i + 1].createdAt * 1000);
    return a.day != b.day || a.month != b.month || a.year != b.year;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final ws = context.watch<WebSocketService>();
    final messages = chat.messages;
    final name = chat.contactName(auth.partnerUsername ?? 'Собеседник');
    final keyStatus = auth.partnerKeyStatus;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Color(chat.contactAvatarColor),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              _subtitle(chat, ws, keyStatus),
            ]),
          ),
        ]),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _search.clear();
              _results = [];
            }),
          ),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _showMenu),
        ],
      ),
      body: Column(children: [
        if (keyStatus == PeerKeyStatus.mismatch) _keyWarning(),
        if (_searching) _searchBar(chat),
        if (_uploading) _uploadBar(),
        Expanded(child: messages.isEmpty ? _empty(chat) : _list(chat, auth, messages)),
        _inputBar(auth.canEncrypt),
      ]),
    );
  }

  Widget _subtitle(ChatProvider chat, WebSocketService ws, PeerKeyStatus status) {
    final style = TextStyle(fontSize: 11, color: Colors.grey[400]);
    if (chat.isPeerTyping) return Text('печатает...', style: style.copyWith(fontStyle: FontStyle.italic));
    if (!ws.isConnected) return Text('нет связи с сервером', style: style.copyWith(color: Colors.orange[300]));
    if (chat.isSyncing) return Text('синхронизация...', style: style);
    switch (status) {
      case PeerKeyStatus.verified:
        return Row(children: [
          Icon(Icons.verified_user, size: 12, color: Colors.green[400]),
          const SizedBox(width: 4),
          Text('шифрование, ключ проверен', style: style.copyWith(color: Colors.green[400])),
        ]);
      case PeerKeyStatus.trusted:
        return Row(children: [
          Icon(Icons.lock, size: 12, color: Colors.green[400]),
          const SizedBox(width: 4),
          Text('шифрование (сверьте отпечаток)', style: style.copyWith(color: Colors.green[400])),
        ]);
      case PeerKeyStatus.mismatch:
        return Text('ключ изменился!', style: style.copyWith(color: Colors.red[300]));
      case PeerKeyStatus.unknown:
        return Text('нет ключа собеседника', style: style.copyWith(color: Colors.orange[300]));
    }
  }

  Widget _keyWarning() => Material(
        color: Colors.red[900],
        child: ListTile(
          leading: const Icon(Icons.warning, color: Colors.white),
          title: const Text('Ключ собеседника изменился', style: TextStyle(color: Colors.white)),
          subtitle: const Text('Отправка заблокирована. Сверьте отпечаток.', style: TextStyle(color: Colors.white70)),
          trailing: const Icon(Icons.chevron_right, color: Colors.white),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SafetyNumberScreen())),
        ),
      );

  Widget _searchBar(ChatProvider chat) {
    return Container(
      color: Colors.grey[850],
      padding: const EdgeInsets.all(8),
      child: Column(children: [
        TextField(
          controller: _search,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Поиск (можно * и ?)',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            filled: true,
            fillColor: Colors.grey[800],
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          ),
          onChanged: (q) => setState(() => _results = chat.search(q)),
        ),
        if (_search.text.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: _results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('Ничего не найдено', style: TextStyle(color: Colors.grey[500])))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in _results)
                        ListTile(
                          dense: true,
                          title: Text(chat.decryptedOf(m)?.text ?? chat.decryptedOf(m)?.file?.name ?? '',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_dateLabel(m.createdAt)),
                          onTap: () {
                            final i = chat.messages.indexOf(m);
                            setState(() => _searching = false);
                            if (i >= 0 && _scroll.hasClients) {
                              _scroll.animateTo((i * 72.0).clamp(0, _scroll.position.maxScrollExtent),
                                  duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                            }
                          },
                        ),
                    ],
                  ),
          ),
      ]),
    );
  }

  Widget _uploadBar() => Container(
        color: Colors.grey[850],
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_uploadProgress == 0 ? 'Шифрование: $_uploadName' : 'Отправка: $_uploadName',
                  style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: _uploadProgress == 0 ? null : _uploadProgress),
            ]),
          ),
        ]),
      );

  Widget _empty(ChatProvider chat) => Center(
        child: chat.isSyncing
            ? const CircularProgressIndicator()
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.lock_outline, size: 48, color: Colors.grey[700]),
                const SizedBox(height: 16),
                Text('Сообщения шифруются на устройствах', style: TextStyle(color: Colors.grey[500])),
                const SizedBox(height: 8),
                Text('Напишите первое сообщение', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              ]),
      );

  Widget _list(ChatProvider chat, AuthProvider auth, List<Message> messages) {
    return Stack(children: [
      ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: messages.length + 1,
        itemBuilder: (context, i) {
          if (i == messages.length) {
            if (chat.isLoadingHistory) {
              return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            }
            if (!chat.hasMoreHistory) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Center(child: Text('Начало переписки', style: TextStyle(color: Colors.grey[600], fontSize: 12))),
              );
            }
            return const SizedBox.shrink();
          }
          final m = messages[i];
          final isMe = m.senderId == auth.userId;
          return Column(key: ValueKey(m.key), children: [
            if (_newDay(messages, i))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Chip(label: Text(_dateLabel(m.createdAt), style: const TextStyle(fontSize: 12))),
              ),
            MessageBubble(message: m, isMe: isMe, onLongPress: () => _showMessageOptions(m, isMe)),
          ]);
        },
      ),
      Positioned(
        right: 16,
        bottom: 16,
        child: AnimatedScale(
          scale: _showScrollDown ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: FloatingActionButton.small(onPressed: _scrollToBottom, child: const Icon(Icons.keyboard_arrow_down)),
        ),
      ),
    ]);
  }

  Widget _inputBar(bool canSend) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.grey[850], border: Border(top: BorderSide(color: Colors.grey[800]!))),
      child: SafeArea(
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            onPressed: _uploading || !canSend ? null : _showAttachMenu,
          ),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 150),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  enabled: canSend,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  onChanged: (t) {
                    if (t.isNotEmpty) _chat.sendTyping();
                  },
                  decoration: InputDecoration(
                    hintText: canSend ? 'Сообщение...' : 'Отправка недоступна — проверьте ключ собеседника',
                    filled: true,
                    fillColor: Colors.grey[800],
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(icon: const Icon(Icons.send), onPressed: canSend ? _send : null),
        ]),
      ),
    );
  }
}
