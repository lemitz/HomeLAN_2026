import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../utils/app_log.dart';

/// Имя файла из метаданных приходит от собеседника — оставляем только
/// базовое имя без путей и служебных символов, чтобы исключить path traversal
/// ("../../x") и попытки записи вне временной директории.
String sanitizeFileName(String? name, String fallback) {
  if (name == null || name.trim().isEmpty) return fallback;
  var base = p.basename(name.replaceAll('\\', '/')).trim();
  base = base.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
  if (base.isEmpty || base == '.' || base == '..') return fallback;
  if (base.length > 120) {
    final ext = p.extension(base);
    base = base.substring(0, 120 - ext.length) + ext;
  }
  return base;
}

// Глобальный кэш превьюшек по seqId
final Map<int, Uint8List> _imageCache = {};

class MessageBubble extends StatefulWidget {
  final Message message;
  final bool isMe;
  final VoidCallback? onLongPress;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.onLongPress,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  String? _decryptedContent;
  bool _isDecrypting = false;
  bool _decryptionFailed = false;
  
  Map<String, dynamic>? _fileMetadata;
  bool _isLoadingImage = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  Uint8List? get _imageData => _imageCache[widget.message.seqId];
  
  set _imageData(Uint8List? value) {
    if (value != null) {
      _imageCache[widget.message.seqId] = value;
    }
  }

  @override
  void initState() {
    super.initState();
    _decryptMessage();
  }

  @override
  void didUpdateWidget(MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.seqId != widget.message.seqId) {
      _fileMetadata = null;
      _isLoadingImage = false;
      _decryptMessage();
    }
  }

  bool get _isFileMessage =>
      widget.message.contentType.contains('file') ||
      widget.message.contentType.contains('image');

  bool get _isImageMessage =>
      widget.message.contentType.contains('image');

  Future<void> _decryptMessage() async {
    if (_isFileMessage) {
      await _loadFileMetadata();
      return;
    }

    if (widget.message.contentType != 'encrypted') {
      setState(() {
        _decryptedContent = widget.message.textContent;
        _isDecrypting = false;
        _decryptionFailed = false;
      });
      return;
    }

    setState(() {
      _isDecrypting = true;
      _decryptionFailed = false;
    });

    try {
      final chatProvider = context.read<ChatProvider>();
      final decrypted = await chatProvider.decryptMessage(widget.message);
      
      if (mounted) {
        setState(() {
          _decryptedContent = decrypted;
          _isDecrypting = false;
          _decryptionFailed = decrypted.startsWith('[');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _decryptedContent = '[Ошибка расшифровки]';
          _isDecrypting = false;
          _decryptionFailed = true;
        });
      }
    }
  }

  Future<void> _loadFileMetadata() async {
    setState(() {
      _isDecrypting = true;
    });

    try {
      final chatProvider = context.read<ChatProvider>();
      final metadata = await chatProvider.getFileMetadata(widget.message);
      
      if (mounted) {
        setState(() {
          _fileMetadata = metadata;
          _isDecrypting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDecrypting = false;
          _decryptionFailed = true;
        });
      }
    }
  }

  Future<void> _loadImagePreview() async {
    if (_imageData != null) {
      setState(() {});
      return;
    }
    
    if (_isLoadingImage) return;

    setState(() {
      _isLoadingImage = true;
    });

    try {
      final chatProvider = context.read<ChatProvider>();
      final imageBytes = await chatProvider.downloadFile(widget.message);
      
      if (mounted) {
        setState(() {
          _imageData = imageBytes;
          _isLoadingImage = false;
        });
      }
    } catch (e) {
      appLog('Failed to load image for seq=${widget.message.seqId}: $e');
      if (mounted) {
        setState(() {
          _isLoadingImage = false;
        });
      }
    }
  }

  /// Открывает изображение в полноэкранном просмотрщике
  void _openImageViewer() {
    final imageBytes = _imageCache[widget.message.seqId];
    if (imageBytes == null) return;
    
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _FullScreenImageViewer(
            imageBytes: imageBytes,
            fileName: _fileMetadata?['file_name'] ?? 'image.jpg',
            onSave: _saveImageToFile,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  /// Сохраняет изображение и открывает во внешнем приложении
  Future<void> _saveImageToFile() async {
    final imageBytes = _imageCache[widget.message.seqId];
    if (imageBytes == null) return;

    try {
      final fileName = sanitizeFileName(
        _fileMetadata?['file_name'] as String?,
        'image_${widget.message.seqId}.jpg',
      );
      final directory = await getTemporaryDirectory();
      final filePath = p.join(directory.path, fileName);
      
      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      await OpenFilex.open(filePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red[700]),
        );
      }
    }
  }

  Future<void> _downloadAndOpenFile() async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
    });

    try {
      final chatProvider = context.read<ChatProvider>();
      
      Uint8List fileBytes;
      if (_imageData != null) {
        fileBytes = _imageData!;
      } else {
        fileBytes = await chatProvider.downloadFile(widget.message);
      }
      
      setState(() {
        _downloadProgress = 0.8;
      });

      final fileName = sanitizeFileName(
        _fileMetadata?['file_name'] as String?,
        'file_${widget.message.seqId}',
      );
      final directory = await getTemporaryDirectory();
      final filePath = p.join(directory.path, fileName);
      
      final file = File(filePath);
      await file.writeAsBytes(fileBytes);

      setState(() {
        _downloadProgress = 1.0;
      });

      final result = await OpenFilex.open(filePath);
      
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Файл сохранён: $filePath'),
            backgroundColor: Colors.green[700],
          ),
        );
      }
    } catch (e) {
      appLog('Download failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red[700]),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = 0.0;
        });
      }
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      color: Colors.grey[850],
      items: [
        if (_isFileMessage && _fileMetadata != null)
          PopupMenuItem<String>(
            value: 'download',
            child: Row(
              children: [
                Icon(Icons.download, color: Colors.grey[300], size: 20),
                const SizedBox(width: 12),
                Text('Скачать', style: TextStyle(color: Colors.grey[300])),
              ],
            ),
          ),
        if (!_isFileMessage && _decryptedContent != null)
          PopupMenuItem<String>(
            value: 'copy',
            child: Row(
              children: [
                Icon(Icons.copy, color: Colors.grey[300], size: 20),
                const SizedBox(width: 12),
                Text('Копировать', style: TextStyle(color: Colors.grey[300])),
              ],
            ),
          ),
        if (widget.isMe)
          PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete, color: Colors.red[400], size: 20),
                const SizedBox(width: 12),
                Text('Удалить', style: TextStyle(color: Colors.red[400])),
              ],
            ),
          ),
      ],
    ).then((value) {
      if (value == 'delete') {
        _confirmDelete();
      } else if (value == 'download') {
        _downloadAndOpenFile();
      } else if (value == 'copy' && _decryptedContent != null) {
        Clipboard.setData(ClipboardData(text: _decryptedContent!));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Скопировано'),
            backgroundColor: Colors.grey[700],
            duration: const Duration(seconds: 1),
          ),
        );
      }
    });
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Удалить сообщение?', style: TextStyle(color: Colors.white)),
        content: const Text('Сообщение будет удалено для всех.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Отмена', style: TextStyle(color: Colors.grey[400])),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final chatProvider = context.read<ChatProvider>();
              chatProvider.deleteMessage(widget.message.seqId);
              _imageCache.remove(widget.message.seqId);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEncrypted = widget.message.contentType.startsWith('encrypted');
    
    return RepaintBoundary(
      child: Align(
        alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: widget.onLongPress,
          onSecondaryTapUp: (details) {
            _showContextMenu(context, details.globalPosition);
          },
          child: Container(
            margin: EdgeInsets.only(
              left: widget.isMe ? 64 : 8,
              right: widget.isMe ? 8 : 64,
              top: 4,
              bottom: 4,
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Color(widget.isMe 
                  ? context.watch<ChatProvider>().myBubbleColor 
                  : context.watch<ChatProvider>().otherBubbleColor),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(widget.isMe ? 16 : 4),
                bottomRight: Radius.circular(widget.isMe ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildContent(),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isEncrypted && !_decryptionFailed) ...[
                      Icon(Icons.lock, size: 10, color: Colors.green[300]),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      _formatTime(widget.message.createdAt),
                      style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11),
                    ),
                    if (widget.isMe) ...[
                      const SizedBox(width: 4),
                      _buildStatusIcon(),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isDecrypting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white.withOpacity(0.7)),
          ),
          const SizedBox(width: 8),
          Text('Расшифровка...', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14, fontStyle: FontStyle.italic)),
        ],
      );
    }

    if (_decryptionFailed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 14, color: Colors.red[300]),
          const SizedBox(width: 4),
          Text(_decryptedContent ?? '[Ошибка]', style: TextStyle(color: Colors.red[300], fontSize: 14, fontStyle: FontStyle.italic)),
        ],
      );
    }

    if (_isImageMessage) return _buildImageContent();
    if (_isFileMessage) return _buildFileContent();

    return Text(_decryptedContent ?? widget.message.textContent, style: const TextStyle(color: Colors.white, fontSize: 16));
  }

  Widget _buildImageContent() {
    final fileName = _fileMetadata?['file_name'] ?? 'Изображение';
    final fileSize = _fileMetadata?['file_size'] ?? 0;
    final cachedImage = _imageCache[widget.message.seqId];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: cachedImage != null
              ? GestureDetector(
                  onTap: _openImageViewer,  // Открываем в просмотрщике
                  child: Image.memory(
                    cachedImage, 
                    width: 200, 
                    height: 200, 
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildImagePlaceholder(fileName, fileSize),
                  ),
                )
              : _isLoadingImage
                  ? Container(
                      width: 200, 
                      height: 150, 
                      color: Colors.grey[700], 
                      child: const Center(child: CircularProgressIndicator()),
                    )
                  : GestureDetector(
                      onTap: _loadImagePreview,
                      child: _buildImagePlaceholder(fileName, fileSize),
                    ),
        ),
        const SizedBox(height: 4),
        Text(
          fileName, 
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12), 
          maxLines: 1, 
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildImagePlaceholder(String fileName, int fileSize) {
    return Container(
      width: 200, 
      height: 150, 
      color: Colors.grey[700],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image, size: 48, color: Colors.grey[500]),
          const SizedBox(height: 8),
          Text('Нажмите для загрузки', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
          Text(_formatFileSize(fileSize), style: TextStyle(color: Colors.grey[500], fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildFileContent() {
    final fileName = _fileMetadata?['file_name'] ?? 'Файл';
    final fileSize = _fileMetadata?['file_size'] ?? 0;
    final mimeType = _fileMetadata?['mime_type'] ?? '';

    return GestureDetector(
      onTap: _downloadAndOpenFile,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.2), 
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: _getFileColor(mimeType), 
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_getFileIcon(mimeType), color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName, 
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500), 
                    maxLines: 1, 
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatFileSize(fileSize), 
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_isDownloading)
              SizedBox(
                width: 24, 
                height: 24, 
                child: CircularProgressIndicator(
                  value: _downloadProgress > 0 ? _downloadProgress : null, 
                  strokeWidth: 2, 
                  color: Colors.white,
                ),
              )
            else
              Icon(Icons.download, color: Colors.white.withOpacity(0.7), size: 24),
          ],
        ),
      ),
    );
  }

  IconData _getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('zip') || mimeType.contains('rar') || mimeType.contains('7z')) return Icons.folder_zip;
    if (mimeType.contains('word') || mimeType.contains('document')) return Icons.description;
    if (mimeType.contains('excel') || mimeType.contains('spreadsheet')) return Icons.table_chart;
    return Icons.insert_drive_file;
  }

  Color _getFileColor(String mimeType) {
    if (mimeType.startsWith('image/')) return Colors.purple;
    if (mimeType.startsWith('video/')) return Colors.red;
    if (mimeType.startsWith('audio/')) return Colors.orange;
    if (mimeType.contains('pdf')) return Colors.red[700]!;
    if (mimeType.contains('zip') || mimeType.contains('rar')) return Colors.amber[700]!;
    if (mimeType.contains('word')) return Colors.blue[700]!;
    if (mimeType.contains('excel')) return Colors.green[700]!;
    return Colors.blueGrey;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildStatusIcon() {
    IconData icon;
    Color color = Colors.white.withOpacity(0.7);
    switch (widget.message.status) {
      case 'pending': icon = Icons.access_time; break;
      case 'sent': icon = Icons.check; break;
      case 'delivered': icon = Icons.done_all; break;
      case 'read': icon = Icons.done_all; color = Colors.lightBlueAccent; break;
      default: icon = Icons.check;
    }
    return Icon(icon, size: 14, color: color);
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

/// Полноэкранный просмотрщик изображений
class _FullScreenImageViewer extends StatefulWidget {
  final Uint8List imageBytes;
  final String fileName;
  final VoidCallback onSave;

  const _FullScreenImageViewer({
    required this.imageBytes,
    required this.fileName,
    required this.onSave,
  });

  @override
  State<_FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<_FullScreenImageViewer> {
  final TransformationController _transformationController = TransformationController();
  
  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.fileName,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _resetZoom,
            tooltip: 'Сбросить масштаб',
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new, color: Colors.white),
            onPressed: widget.onSave,
            tooltip: 'Открыть в приложении',
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          transformationController: _transformationController,
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.memory(
            widget.imageBytes,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}