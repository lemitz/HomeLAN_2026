// lib/widgets/message_bubble.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/providers.dart';

/// Расширения, которые при открытии могут выполнить код.
const _dangerousExtensions = {
  'exe',
  'bat',
  'cmd',
  'com',
  'msi',
  'ps1',
  'vbs',
  'js',
  'jse',
  'wsf',
  'scr',
  'lnk',
  'hta',
  'reg',
  'jar',
  'apk',
  'sh',
  'pif',
  'cpl',
  'msc',
  'dll',
};

class MessageBubble extends StatefulWidget {
  final Message message;
  final bool isMe;
  final VoidCallback? onLongPress;

  const MessageBubble({super.key, required this.message, required this.isMe, this.onLongPress});

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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось загрузить файл: $e'), backgroundColor: Colors.red[700]));
      }
      return null;
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _open(FileMeta meta) async {
    final ext = meta.name.contains('.') ? meta.name.split('.').last.toLowerCase() : '';
    if (_dangerousExtensions.contains(ext)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Открыть исполняемый файл?'),
          content: Text('«${meta.name}» может запустить программу на этом устройстве. '
              'Открывайте, только если уверены в источнике.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Открыть')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final path = await _ensureDownloaded();
    if (path == null) return;
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Нет приложения для открытия: ${meta.name}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final d = chat.decryptedOf(m);
    final color = Color(widget.isMe ? chat.myBubbleColor : chat.otherBubbleColor);

    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onLongPress,
        child: Container(
          margin: EdgeInsets.only(left: widget.isMe ? 64 : 8, right: widget.isMe ? 8 : 64, top: 3, bottom: 3),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(widget.isMe ? 16 : 4),
              bottomRight: Radius.circular(widget.isMe ? 4 : 16),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _content(d),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_time(m.createdAt), style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11)),
              if (widget.isMe) ...[const SizedBox(width: 4), _status()],
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _content(DecryptedContent? d) {
    if (d == null) {
      return Text('Расшифровка...',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontStyle: FontStyle.italic));
    }
    if (d.isError) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock_outline, size: 14, color: Colors.red[300]),
        const SizedBox(width: 4),
        Flexible(child: Text(d.error!, style: TextStyle(color: Colors.red[300], fontStyle: FontStyle.italic))),
      ]);
    }
    if (d.file != null) return m.isImage ? _image(d.file!) : _file(d.file!);
    return SelectableText(d.text ?? '', style: const TextStyle(color: Colors.white, fontSize: 16));
  }

  Widget _image(FileMeta meta) {
    final canPreview = meta.size <= _previewLimit;
    if (_localPath != null && canPreview) {
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => _ImageViewer(path: _localPath!, meta: meta, onOpen: () => _open(meta))),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(File(_localPath!),
              width: 220,
              fit: BoxFit.cover,
              cacheWidth: 660,
              errorBuilder: (_, __, ___) => _filePlaceholder(meta, Icons.broken_image)),
        ),
      );
    }
    return GestureDetector(
      onTap: canPreview ? _ensureDownloaded : () => _open(meta),
      child: _filePlaceholder(meta, Icons.image),
    );
  }

  Widget _filePlaceholder(FileMeta meta, IconData icon) => Container(
        width: 220,
        height: 140,
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (_downloading)
            CircularProgressIndicator(value: _progress > 0 ? _progress : null)
          else
            Icon(icon, size: 40, color: Colors.white70),
          const SizedBox(height: 8),
          Text(_downloading ? 'Загрузка...' : 'Нажмите, чтобы загрузить',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(_size(meta.size), style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
      );

  Widget _file(FileMeta meta) {
    return GestureDetector(
      onTap: () => _open(meta),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.insert_drive_file, color: Colors.white, size: 32),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(meta.name,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              Text(_size(meta.size), style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          _downloading
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(value: _progress > 0 ? _progress : null, strokeWidth: 2))
              : const Icon(Icons.download, color: Colors.white70),
        ]),
      ),
    );
  }

  Widget _status() {
    final white = Colors.white.withValues(alpha: 0.7);
    switch (m.deliveryStatus) {
      case DeliveryStatus.pending:
        return Icon(Icons.access_time, size: 14, color: white);
      case DeliveryStatus.failed:
        return Tooltip(
            message: m.failReason ?? 'Не отправлено',
            child: Icon(Icons.error_outline, size: 14, color: Colors.red[200]));
      case DeliveryStatus.sent:
        return Icon(Icons.check, size: 14, color: white);
      case DeliveryStatus.delivered:
        return Icon(Icons.done_all, size: 14, color: white);
      case DeliveryStatus.read:
        return const Icon(Icons.done_all, size: 14, color: Colors.lightBlueAccent);
    }
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
  final VoidCallback onOpen;

  const _ImageViewer({required this.path, required this.meta, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(meta.name, overflow: TextOverflow.ellipsis),
        actions: [IconButton(icon: const Icon(Icons.open_in_new), tooltip: 'Открыть в приложении', onPressed: onOpen)],
      ),
      body: Center(
        child: InteractiveViewer(minScale: 0.5, maxScale: 5, child: Image.file(File(path), fit: BoxFit.contain)),
      ),
    );
  }
}
