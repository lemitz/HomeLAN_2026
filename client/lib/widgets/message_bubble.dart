// lib/widgets/message_bubble.dart
//
// Пузырь сообщения. Для плавной прокрутки:
// * подписка только на своё содержимое и цвета (context.select), а не на весь чат;
// * RepaintBoundary — перерисовка одного пузыря не трогает соседей;
// * MediaQuery.sizeOf — клавиатура не перестраивает все пузыри;
// * обычный Text вместо SelectableText (копирование — через меню).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../theme.dart';

/// Расширения, которые при открытии могут выполнить код.
const _dangerousExtensions = {
  'exe', 'bat', 'cmd', 'com', 'msi', 'ps1', 'vbs', 'js', 'jse', 'wsf', 'scr', //
  'lnk', 'hta', 'reg', 'jar', 'apk', 'sh', 'pif', 'cpl', 'msc', 'dll',
};

class MessageBubble extends StatefulWidget {
  final Message message;
  final bool isMe;

  /// Последнее сообщение в серии подряд от одного отправителя — с «хвостиком».
  final bool tail;
  final VoidCallback? onLongPress;

  const MessageBubble({super.key, required this.message, required this.isMe, this.tail = true, this.onLongPress});

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  String? _localPath; // расшифрованный файл
  bool _downloading = false;
  double _progress = 0;

  static const _previewLimit = 25 * 1024 * 1024;

  Message get m => widget.message;

  Future<String?> _ensureDownloaded() async {
    if (_localPath != null && await File(_localPath!).exists()) return _localPath;
    if (_downloading || !mounted) return null;
    final chat = context.read<ChatProvider>();
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      final path = await chat.downloadFile(m, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _localPath = path);
      return path;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).downloadFailed)));
      }
      return null;
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _open(FileMeta meta) async {
    final s = S.of(context);
    final ext = meta.name.contains('.') ? meta.name.split('.').last.toLowerCase() : '';
    if (_dangerousExtensions.contains(ext)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.openExecTitle),
          content: Text(s.openExecBody(meta.name)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.open)),
          ],
        ),
      );
      if (ok != true) return;
    }
    final path = await _ensureDownloaded();
    if (path == null) return;
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.noAppToOpen)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.select<ChatProvider, DecryptedContent?>((c) => c.decryptedOf(m));
    final colorValue = context.select<ChatProvider, int>((c) => widget.isMe ? c.myBubbleColor : c.otherBubbleColor);
    final maxWidth = MediaQuery.sizeOf(context).width * (MediaQuery.sizeOf(context).width > 700 ? 0.55 : 0.78);
    final isMe = widget.isMe;
    const r = Radius.circular(18);
    const small = Radius.circular(6);

    return RepaintBoundary(
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: widget.onLongPress,
          onSecondaryTap: widget.onLongPress,
          child: AnimatedContainer(
            duration: kMedium,
            margin:
                EdgeInsets.only(left: isMe ? 56 : 10, right: isMe ? 10 : 56, top: 1.5, bottom: widget.tail ? 6 : 1.5),
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: EdgeInsets.fromLTRB(m.isFile ? 6 : 12, m.isFile ? 6 : 8, m.isFile ? 6 : 12, 6),
            decoration: BoxDecoration(
              color: Color(colorValue),
              borderRadius: BorderRadius.only(
                topLeft: r,
                topRight: r,
                bottomLeft: isMe || !widget.tail ? r : small,
                bottomRight: !isMe || !widget.tail ? r : small,
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              _content(d),
              Padding(
                padding: EdgeInsets.only(top: 3, right: m.isFile ? 6 : 0),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_time(m.createdAt), style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11)),
                  if (isMe) ...[const SizedBox(width: 4), _status()],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _content(DecryptedContent? d) {
    if (d == null) {
      return SizedBox(
        width: 60,
        height: 18,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 48,
            height: 8,
            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
          ),
        ),
      );
    }
    if (d.isError) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline, size: 14, color: Color(0xFFFFA198)),
        const SizedBox(width: 4),
        Flexible(child: Text(d.error!, style: const TextStyle(color: Color(0xFFFFA198), fontStyle: FontStyle.italic))),
      ]);
    }
    if (d.file != null) return m.isImage ? _image(d.file!) : _file(d.file!);
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Text(d.text ?? '', style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.3)),
    );
  }

  Widget _image(FileMeta meta) {
    final canPreview = meta.size <= _previewLimit;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_localPath != null && canPreview) {
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          PageRouteBuilder(
            opaque: false,
            transitionDuration: kMedium,
            reverseTransitionDuration: kFast,
            pageBuilder: (_, __, ___) =>
                _ImageViewer(path: _localPath!, meta: meta, heroTag: 'img:${m.key}', onOpen: () => _open(meta)),
            transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
          ),
        ),
        child: Hero(
          tag: 'img:${m.key}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.file(
              File(_localPath!),
              width: 240,
              fit: BoxFit.cover,
              cacheWidth: (240 * dpr).round(),
              frameBuilder: (_, child, frame, sync) =>
                  sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: kMedium, child: child),
              errorBuilder: (_, __, ___) => _placeholder(meta, Icons.broken_image_outlined),
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: canPreview ? _ensureDownloaded : () => _open(meta),
      child: _placeholder(meta, Icons.download_rounded),
    );
  }

  Widget _placeholder(FileMeta meta, IconData icon) => Container(
        width: 240,
        height: 150,
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedSwitcher(
            duration: kFast,
            child: _downloading
                ? SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(value: _progress > 0 ? _progress : null, strokeWidth: 3))
                : Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                    child: Icon(icon, color: Colors.white),
                  ),
          ),
          const SizedBox(height: 8),
          Text(_size(meta.size), style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ]),
      );

  Widget _file(FileMeta meta) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(meta),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: Colors.black26, shape: BoxShape.circle),
            child: AnimatedSwitcher(
              duration: kFast,
              child: _downloading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(value: _progress > 0 ? _progress : null, strokeWidth: 2.5))
                  : Icon(_localPath != null ? Icons.insert_drive_file_outlined : Icons.download_rounded,
                      color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(meta.name,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(_size(meta.size), style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _status() {
    final white = Colors.white.withValues(alpha: 0.7);
    final Widget icon = switch (m.deliveryStatus) {
      DeliveryStatus.pending => Icon(Icons.schedule, size: 14, color: white),
      DeliveryStatus.failed => Tooltip(
          message: m.failReason ?? S.of(context).notSentShort,
          child: const Icon(Icons.error_outline, size: 14, color: Color(0xFFFFA198))),
      DeliveryStatus.sent => Icon(Icons.check, size: 14, color: white),
      DeliveryStatus.delivered => Icon(Icons.done_all, size: 14, color: white),
      DeliveryStatus.read => const Icon(Icons.done_all, size: 14, color: Color(0xFF8CE0FF)),
    };
    return AnimatedSwitcher(
      duration: kFast,
      transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
      child: KeyedSubtree(key: ValueKey(m.deliveryStatus), child: icon),
    );
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static String _time(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _ImageViewer extends StatelessWidget {
  final String path;
  final FileMeta meta;
  final String heroTag;
  final VoidCallback onOpen;

  const _ImageViewer({required this.path, required this.meta, required this.heroTag, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(meta.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
        actions: [IconButton(icon: const Icon(Icons.open_in_new), tooltip: S.of(context).open, onPressed: onOpen)],
      ),
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Hero(tag: heroTag, child: Image.file(File(path), fit: BoxFit.contain)),
          ),
        ),
      ),
    );
  }
}
