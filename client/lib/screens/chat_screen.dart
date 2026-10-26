// lib/screens/chat_screen.dart
//
// Экран переписки. Части экрана подписаны на свои данные отдельно:
// список — на ревизию сообщений, заголовок — на статус, поле ввода — только
// на свой текст. Набор текста, «печатает» и расшифровка не перестраивают список.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/services.dart';
import '../theme.dart';
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
  final _showScrollDown = ValueNotifier(false);
  late final ChatProvider _chat;

  bool _searching = false;
  List<Message> _results = [];
  bool _uploading = false;
  final _uploadProgress = ValueNotifier<double>(0);
  String? _uploadName;

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
    _showScrollDown.dispose();
    _uploadProgress.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // «Прочитано» отмечаем только когда чат реально на экране.
    _chat.setChatVisible(state == AppLifecycleState.resumed);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _showScrollDown.value = _scroll.offset > 300;
    if (_scroll.offset >= _scroll.position.maxScrollExtent - 400) _chat.loadOlder();
  }

  void _scrollToBottom() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0, duration: kMedium, curve: Curves.easeOutCubic);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await _chat.sendText(text);
      _scrollToBottom();
    } catch (e) {
      _input.text = text;
      if (mounted) showSnack(context, e.toString(), error: true);
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

  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  Future<void> _pickImage(ImageSource source) async {
    try {
      final image = await BiometricService().withoutLock(
        () => _imagePicker.pickImage(source: source, maxWidth: 2560, maxHeight: 2560, imageQuality: 85),
      );
      // На мобильных пикер отдаёт копию в кеше приложения — её удаляем.
      // На ПК это оригинальный файл пользователя — его не трогаем.
      if (image != null) await _upload(File(image.path), isImage: true, temporary: _mobile);
    } catch (_) {
      if (mounted) showSnack(context, S.of(context).pickFailed, error: true);
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await BiometricService().withoutLock(() => FilePicker.platform.pickFiles());
      final path = result?.files.single.path;
      if (path != null) await _upload(File(path), temporary: _mobile);
    } catch (_) {
      if (mounted) showSnack(context, S.of(context).pickFailed, error: true);
    }
  }

  Future<void> _upload(File file, {bool isImage = false, bool temporary = false}) async {
    if (!mounted) return;
    setState(() {
      _uploading = true;
      _uploadName = file.uri.pathSegments.last;
    });
    _uploadProgress.value = 0;
    try {
      await _chat.sendFile(file, isImage: isImage, onProgress: (p) => _uploadProgress.value = p);
      _scrollToBottom();
    } catch (e) {
      if (mounted) showSnack(context, S.of(context).notSent(e), error: true);
    } finally {
      if (temporary) {
        file.delete().catchError((_) => file);
        if (_mobile) FilePicker.platform.clearTemporaryFiles();
      }
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showAttachMenu() {
    final s = S.of(context);
    showActions(context, [
      SheetAction(Icons.image_outlined, s.gallery, () => _pickImage(ImageSource.gallery)),
      if (_mobile) SheetAction(Icons.photo_camera_outlined, s.camera, () => _pickImage(ImageSource.camera)),
      SheetAction(Icons.insert_drive_file_outlined, s.file, _pickFile),
    ]);
  }

  // ============ МЕНЮ ============

  void _showMessageOptions(Message m, bool isMe) {
    final s = S.of(context);
    final d = _chat.decryptedOf(m);
    showActions(context, [
      if (d?.text != null)
        SheetAction(Icons.copy_rounded, s.copy, () {
          Clipboard.setData(ClipboardData(text: d!.text!));
          showSnack(context, s.copied);
        }),
      if (isMe && m.localStatus == LocalStatus.failed) SheetAction(Icons.refresh, s.resend, () => _chat.retry(m)),
      if (isMe)
        SheetAction(Icons.delete_outline, m.seqId == null ? s.delete : s.deleteForAll, () => _chat.deleteMessage(m),
            danger: true),
    ]);
  }

  void _showMenu() {
    final s = S.of(context);
    void push(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    showActions(context, [
      SheetAction(Icons.edit_outlined, s.editContact, _editContact),
      SheetAction(Icons.fingerprint, s.safetyNumber, () => push(const SafetyNumberScreen())),
      SheetAction(Icons.devices_outlined, s.devices, () => push(const DevicesScreen())),
      SheetAction(Icons.settings_outlined, s.settings, () => push(const SettingsScreen())),
    ]);
  }

  void _editContact() {
    final s = S.of(context);
    final auth = context.read<AuthProvider>();
    final controller = TextEditingController(text: _chat.contactName(auth.partnerUsername ?? ''));
    var color = _chat.contactAvatarColor;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(s.editContact),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: controller, autofocus: true, decoration: InputDecoration(hintText: s.name)),
            const SizedBox(height: 20),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final c in AppColors.avatarPalette)
                GestureDetector(
                  onTap: () => setD(() => color = c.toARGB32()),
                  child: AnimatedContainer(
                    duration: kFast,
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: color == c.toARGB32() ? Colors.white : Colors.transparent, width: 3),
                    ),
                  ),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () {
                _chat.saveContact(controller.text.trim(), color);
                Navigator.pop(ctx);
              },
              child: Text(s.save),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  void _toggleSearch() => setState(() {
        _searching = !_searching;
        _search.clear();
        _results = [];
      });

  void _jumpTo(Message m) {
    final i = _chat.messages.indexOf(m);
    setState(() => _searching = false);
    if (i >= 0 && _scroll.hasClients) {
      _scroll.animateTo((i * 64.0).clamp(0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
  }

  // ============ BUILD ============

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final keyStatus = context.select<AuthProvider, PeerKeyStatus>((a) => a.partnerKeyStatus);
    final canSend = keyStatus == PeerKeyStatus.trusted || keyStatus == PeerKeyStatus.verified;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 16,
        title: const _ChatTitle(),
        actions: [
          IconButton(
            tooltip: s.search,
            icon: AnimatedSwitcher(
              duration: kFast,
              transitionBuilder: (c, a) => RotationTransition(turns: Tween(begin: 0.75, end: 1.0).animate(a), child: c),
              child: Icon(_searching ? Icons.close : Icons.search, key: ValueKey(_searching)),
            ),
            onPressed: _toggleSearch,
          ),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _showMenu),
        ],
      ),
      body: Column(children: [
        _Collapsible(visible: keyStatus == PeerKeyStatus.mismatch, child: _keyWarning(s)),
        _Collapsible(visible: _searching, child: _searchBar(s)),
        _Collapsible(visible: _uploading, child: _uploadBar(s)),
        Expanded(
          child: Stack(children: [
            _MessageList(scroll: _scroll, onLongPress: _showMessageOptions),
            Positioned(
              right: 16,
              bottom: 16,
              child: ValueListenableBuilder<bool>(
                valueListenable: _showScrollDown,
                builder: (_, show, child) => AnimatedScale(
                  scale: show ? 1 : 0,
                  duration: kFast,
                  curve: Curves.easeOutBack,
                  child: child,
                ),
                child: FloatingActionButton.small(
                  heroTag: null,
                  backgroundColor: AppColors.surfaceHigh,
                  onPressed: _scrollToBottom,
                  child: const Icon(Icons.keyboard_arrow_down),
                ),
              ),
            ),
          ]),
        ),
        _inputBar(s, canSend),
      ]),
    );
  }

  Widget _keyWarning(S s) => Material(
        color: AppColors.danger.withValues(alpha: 0.15),
        child: ListTile(
          leading: const Icon(Icons.gpp_maybe_outlined, color: AppColors.danger),
          title: Text(s.keyChangedBanner, style: const TextStyle(color: AppColors.danger)),
          trailing: TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SafetyNumberScreen())),
            child: Text(s.verify),
          ),
        ),
      );

  Widget _searchBar(S s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(children: [
        TextField(
          controller: _search,
          autofocus: true,
          decoration: InputDecoration(
            hintText: s.search,
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          ),
          onChanged: (q) => setState(() => _results = _chat.search(q)),
        ),
        AnimatedSize(
          duration: kMedium,
          curve: Curves.easeOutCubic,
          child: _search.text.isEmpty
              ? const SizedBox(width: double.infinity)
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: _results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(s.nothingFound, style: const TextStyle(color: AppColors.muted)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _results.length,
                          itemBuilder: (_, i) {
                            final m = _results[i];
                            final d = _chat.decryptedOf(m);
                            return ListTile(
                              dense: true,
                              title: Text(d?.text ?? d?.file?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(s.dateLabel(DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000)),
                                  style: const TextStyle(color: AppColors.muted)),
                              onTap: () => _jumpTo(m),
                            );
                          },
                        ),
                ),
        ),
      ]),
    );
  }

  Widget _uploadBar(S s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: ValueListenableBuilder<double>(
          valueListenable: _uploadProgress,
          builder: (_, p, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p == 0 ? s.encrypting : s.uploading} · ${_uploadName ?? ''}',
                style: const TextStyle(fontSize: 13, color: AppColors.muted), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: p),
                duration: kFast,
                builder: (_, v, __) => LinearProgressIndicator(value: p == 0 ? null : v, minHeight: 4),
              ),
            ),
          ]),
        ),
      );

  Widget _inputBar(S s, bool canSend) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
      decoration: const BoxDecoration(color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.outline))),
      child: SafeArea(
        top: false,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            color: AppColors.muted,
            onPressed: _uploading || !canSend ? null : _showAttachMenu,
          ),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  enabled: canSend,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (t) {
                    if (t.isNotEmpty) _chat.sendTyping();
                  },
                  decoration: InputDecoration(
                    hintText: canSend ? s.messageHint : s.sendingBlocked,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                    enabledBorder:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                    focusedBorder:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Кнопка отправки появляется, когда есть текст.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (_, v, __) {
              final active = canSend && v.text.trim().isNotEmpty;
              return AnimatedScale(
                scale: active ? 1 : 0.8,
                duration: kFast,
                curve: Curves.easeOutBack,
                child: AnimatedOpacity(
                  opacity: active ? 1 : 0.4,
                  duration: kFast,
                  child: IconButton.filled(
                    onPressed: active ? _send : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }
}

/// Раскрывающаяся панель (баннер, поиск, загрузка).
class _Collapsible extends StatelessWidget {
  final bool visible;
  final Widget child;
  const _Collapsible({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: kMedium,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: visible ? child : const SizedBox(width: double.infinity),
      );
}

/// Заголовок: аватар, имя и одна строка статуса (только когда есть что сказать).
class _ChatTitle extends StatelessWidget {
  const _ChatTitle();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final partner = context.select<AuthProvider, String?>((a) => a.partnerUsername) ?? s.contact;
    final keyStatus = context.select<AuthProvider, PeerKeyStatus>((a) => a.partnerKeyStatus);
    final name = context.select<ChatProvider, String>((c) => c.contactName(partner));
    final color = context.select<ChatProvider, int>((c) => c.contactAvatarColor);
    final typing = context.select<ChatProvider, bool>((c) => c.isPeerTyping);
    final syncing = context.select<ChatProvider, bool>((c) => c.isSyncing);
    final connected = context.select<WebSocketService, bool>((w) => w.isConnected);

    Widget? status;
    if (typing) {
      status = Row(key: const ValueKey('typing'), mainAxisSize: MainAxisSize.min, children: [
        const TypingDots(),
        const SizedBox(width: 6),
        Text(s.typing, style: const TextStyle(fontSize: 12, color: AppColors.accent)),
      ]);
    } else if (!connected) {
      status =
          Text(s.offline, key: const ValueKey('off'), style: const TextStyle(fontSize: 12, color: AppColors.warning));
    } else if (keyStatus == PeerKeyStatus.mismatch) {
      status = Text(s.keyChangedShort,
          key: const ValueKey('key'), style: const TextStyle(fontSize: 12, color: AppColors.danger));
    } else if (keyStatus == PeerKeyStatus.unknown) {
      status = Text(s.noKeyShort,
          key: const ValueKey('nokey'), style: const TextStyle(fontSize: 12, color: AppColors.warning));
    } else if (syncing) {
      status =
          Text(s.syncing, key: const ValueKey('sync'), style: const TextStyle(fontSize: 12, color: AppColors.muted));
    }

    return Row(children: [
      Avatar(name: name, color: Color(color), size: 38),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Flexible(
              child: Text(name,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (keyStatus == PeerKeyStatus.verified) ...[
              const SizedBox(width: 4),
              const Icon(Icons.verified, size: 15, color: AppColors.success),
            ],
          ]),
          AnimatedSize(
            duration: kFast,
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: kFast,
              layoutBuilder: (cur, prev) =>
                  Stack(alignment: Alignment.centerLeft, children: [...prev, if (cur != null) cur]),
              child: status ?? const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// Список сообщений. Перестраивается только при изменении набора сообщений.
class _MessageList extends StatelessWidget {
  final ScrollController scroll;
  final void Function(Message m, bool isMe) onLongPress;

  const _MessageList({required this.scroll, required this.onLongPress});

  static bool _sameDay(int a, int b) {
    final x = DateTime.fromMillisecondsSinceEpoch(a * 1000);
    final y = DateTime.fromMillisecondsSinceEpoch(b * 1000);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  @override
  Widget build(BuildContext context) {
    context.select<ChatProvider, int>((c) => c.revision);
    final chat = context.read<ChatProvider>();
    final me = context.select<AuthProvider, int?>((a) => a.userId);
    final messages = chat.messages;
    final s = S.of(context);

    if (messages.isEmpty) {
      return Center(
        child: AnimatedSwitcher(
          duration: kMedium,
          child: chat.isSyncing
              ? const CircularProgressIndicator()
              : FadeSlideIn(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.lock_outline, size: 40, color: AppColors.muted.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    Text(s.noMessages, style: const TextStyle(color: AppColors.muted)),
                  ]),
                ),
        ),
      );
    }

    return ListView.builder(
      controller: scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      cacheExtent: 1200,
      itemCount: messages.length + (chat.isLoadingHistory ? 1 : 0),
      findChildIndexCallback: (key) {
        if (key is ValueKey<String>) {
          final i = messages.indexWhere((m) => m.key == key.value);
          return i < 0 ? null : i;
        }
        return null;
      },
      itemBuilder: (context, i) {
        if (i == messages.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final m = messages[i];
        final isMe = m.senderId == me;
        // Список перевёрнут: i-1 — более новое сообщение (ниже), i+1 — более старое (выше).
        final newer = i > 0 ? messages[i - 1] : null;
        final older = i + 1 < messages.length ? messages[i + 1] : null;
        final tail = newer == null || newer.senderId != m.senderId || !_sameDay(newer.createdAt, m.createdAt);
        final dayStart = older == null || !_sameDay(older.createdAt, m.createdAt);

        return KeyedSubtree(
          key: ValueKey(m.key),
          child: MessageAppear(
            animate: chat.takeAppear(m.key),
            fromRight: isMe,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (dayStart) _DayChip(label: s.dateLabel(DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000))),
              MessageBubble(message: m, isMe: isMe, tail: tail, onLongPress: () => onLongPress(m, isMe)),
            ]),
          ),
        );
      },
    );
  }
}

class _DayChip extends StatelessWidget {
  final String label;
  const _DayChip({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
          child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        ),
      );
}
