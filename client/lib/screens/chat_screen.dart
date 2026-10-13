// lib/screens/chat_screen.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../widgets/widgets.dart';
import 'settings_screen.dart';
import 'devices_screen.dart';

class ChatScreen extends StatefulWidget {
  final int userId;
  final String username;
  final bool isRootScreen;

  const ChatScreen({
    super.key,
    required this.userId,
    required this.username,
    this.isRootScreen = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _imagePicker = ImagePicker();
  
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String? _uploadingFileName;

  bool _isSearching = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  List<Message> _searchResults = [];

  Timer? _typingTimer;
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _scrollController.addListener(_onScrollForLoadMore);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initChat();
    });
  }

  Future<void> _initChat() async {
    final chat = context.read<ChatProvider>();
    final auth = context.read<AuthProvider>();
    
    // Убедимся что userId установлен
    if (auth.userId != null && chat.myUserId == null) {
      chat.setUserId(auth.userId!);
    }
    
    chat.setActiveChat(widget.userId);
    await chat.loadLocalMessages(widget.userId);
    await chat.loadContactSettings(widget.userId);
    chat.markChatAsRead(widget.userId);
    
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearActiveChat();
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _typingTimer?.cancel();
    super.dispose();
  }

  Future<void> _clearActiveChat() async {
    try {
      final chat = context.read<ChatProvider>();
      chat.setActiveChat(null);
    } catch (e) {
      // Ignore
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final chat = context.read<ChatProvider>();
      chat.setActiveChat(widget.userId);
      chat.loadLocalMessages(widget.userId);
      chat.markChatAsRead(widget.userId);
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final chat = context.read<ChatProvider>();
    _messageController.clear();
    _focusNode.requestFocus();

    try {
      await chat.sendMessage(widget.userId, text);
      _scrollToBottom();
    } on SendMessageException catch (e) {
      // Возвращаем текст в поле, чтобы он не потерялся
      _messageController.text = text;
      _showError(e.message);
    } catch (e) {
      _messageController.text = text;
      _showError('Не удалось отправить сообщение');
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchResults = [];
        _searchController.clear();
      }
    });
  }

  void _onSearchChanged(String query) async {
    setState(() {
      _searchQuery = query;
    });
    
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
      });
    } else {
      final chat = context.read<ChatProvider>();
      final results = await chat.searchMessages(widget.userId, query);
      if (mounted && _searchQuery == query) {
        setState(() {
          _searchResults = results;
        });
      }
    }
  }

  void _onTextChanged(String text) {
    if (text.isNotEmpty) {
      if (_typingTimer == null || !_typingTimer!.isActive) {
        final chat = context.read<ChatProvider>();
        chat.sendTyping(widget.userId);
        _typingTimer = Timer(const Duration(seconds: 2), () {});
      }
    }
  }

  void _onScroll() {
    final showButton = _scrollController.hasClients && 
                       _scrollController.offset > 200;
    
    if (showButton != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = showButton;
      });
    }
  }

  void _onScrollForLoadMore() {
    if (!_scrollController.hasClients) return;
    
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    
    if (currentScroll >= maxScroll - 200) {
      final chat = context.read<ChatProvider>();
      if (chat.hasMoreMessages(widget.userId) && !chat.isLoadingMore(widget.userId)) {
        chat.loadMoreMessages(widget.userId);
      }
    }
  }

  void _scrollToMessage(Message message) {
    final chat = context.read<ChatProvider>();
    final messages = chat.chats[widget.userId] ?? [];
    final index = messages.indexWhere((m) => m.seqId == message.seqId);
    
    if (index != -1 && _scrollController.hasClients) {
      _scrollController.animateTo(
        index * 80.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    
    _toggleSearch();
  }

  String _formatSearchDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Сегодня ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    
    return '${date.day}.${date.month}.${date.year}';
  }

  String _formatDateSeparator(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Сегодня';
    } else if (date.year == yesterday.year && date.month == yesterday.month && date.day == yesterday.day) {
      return 'Вчера';
    } else if (date.year == now.year) {
      const months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 
                      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
      return '${date.day} ${months[date.month - 1]}';
    } else {
      const months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
                      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
      return '${date.day} ${months[date.month - 1]} ${date.year}';
    }
  }

  bool _shouldShowDateSeparator(List<Message> messages, int index) {
    if (index == messages.length - 1) return true;
    
    final current = DateTime.fromMillisecondsSinceEpoch(messages[index].createdAt * 1000);
    final previous = DateTime.fromMillisecondsSinceEpoch(messages[index + 1].createdAt * 1000);
    
    return current.day != previous.day || 
           current.month != previous.month || 
           current.year != previous.year;
  }

  Widget _buildDateSeparator(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.grey[800]?.withOpacity(0.7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  void _showEditContactDialog() {
    final chat = context.read<ChatProvider>();
    final currentName = chat.getContactName(widget.userId, widget.username);
    final currentColor = chat.getContactAvatarColor(widget.userId);
    
    final nameController = TextEditingController(text: currentName);
    int selectedColor = currentColor;
    
    final colors = [
      Colors.blue, Colors.red, Colors.green, Colors.purple,
      Colors.orange, Colors.teal, Colors.pink, Colors.indigo,
    ];
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Редактировать контакт', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Имя',
                  labelStyle: TextStyle(color: Colors.grey[400]),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey[600]!),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('Цвет аватарки', style: TextStyle(color: Colors.grey[400])),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: colors.map((color) => GestureDetector(
                  onTap: () => setDialogState(() => selectedColor = color.value),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: selectedColor == color.value
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                    ),
                  ),
                )).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Отмена', style: TextStyle(color: Colors.grey[400])),
            ),
            ElevatedButton(
              onPressed: () {
                chat.saveContactSettings(
                  widget.userId,
                  nameController.text.trim(),
                  selectedColor,
                );
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[850],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title: const Text('Редактировать контакт', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showEditContactDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.devices, color: Colors.white),
              title: const Text('Мои устройства', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DevicesScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings, color: Colors.white),
              title: const Text('Настройки', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      } else {
        _sendMessage();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[850],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.purple[700],
                child: const Icon(Icons.image, color: Colors.white),
              ),
              title: const Text('Фото из галереи', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            if (Platform.isAndroid || Platform.isIOS)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.blue[700],
                  child: const Icon(Icons.camera_alt, color: Colors.white),
                ),
                title: const Text('Сделать фото', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.orange[700],
                child: const Icon(Icons.insert_drive_file, color: Colors.white),
              ),
              title: const Text('Файл', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickFile();
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      
      if (image != null) {
        await _uploadFile(File(image.path), isImage: true);
      }
    } catch (e) {
      _showError('Не удалось выбрать изображение: $e');
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
        withReadStream: true,
      );
      
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        
        if (file.size > 100 * 1024 * 1024) {
          _showError('Файл слишком большой. Максимум 100 MB');
          return;
        }
        
        if (file.path != null) {
          await _uploadFile(File(file.path!));
        }
      }
    } catch (e) {
      _showError('Не удалось выбрать файл: $e');
    }
  }

  Future<void> _uploadFile(File file, {bool isImage = false}) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    
    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
      _uploadingFileName = fileName;
    });

    try {
      final chat = context.read<ChatProvider>();
      
      await chat.sendFile(
        recipientId: widget.userId,
        file: file,
        fileName: fileName,
        isImage: isImage,
        onProgress: (progress) {
          setState(() {
            _uploadProgress = progress;
          });
        },
      );
      
      _scrollToBottom();
      
    } on SendMessageException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Ошибка загрузки: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadProgress = 0.0;
          _uploadingFileName = null;
        });
      }
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red[700]),
      );
    }
  }

  void _showMessageOptions(int seqId, bool isMe) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[850],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Удалить', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  final chat = context.read<ChatProvider>();
                  chat.deleteMessage(seqId);
                },
              ),
            ListTile(
              leading: Icon(Icons.copy, color: Colors.grey[400]),
              title: Text('Копировать', style: TextStyle(color: Colors.grey[300])),
              onTap: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final messages = chat.chats[widget.userId] ?? [];

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[850],
        // ВАЖНО: Убираем кнопку назад для root экрана
        automaticallyImplyLeading: !widget.isRootScreen,
        leading: widget.isRootScreen ? null : IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Consumer<ChatProvider>(
          builder: (context, chat, _) {
            final displayName = chat.getContactName(widget.userId, widget.username);
            final avatarColor = Color(chat.getContactAvatarColor(widget.userId));
            
            return Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: avatarColor,
                  child: Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      Consumer<ChatProvider>(
                        builder: (context, chat, _) {
                          final isTyping = chat.isUserTyping(widget.userId);
                          
                          if (isTyping) {
                            return Text(
                              'печатает...',
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                              ),
                            );
                          }
                          
                          return Row(
                            children: [
                              Icon(Icons.lock, size: 12, color: Colors.green[400]),
                              const SizedBox(width: 4),
                              Text(
                                'E2E encrypted',
                                style: TextStyle(color: Colors.green[400], fontSize: 11),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search, color: Colors.white),
            onPressed: _toggleSearch,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: _showMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          // Строка поиска
          if (_isSearching)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.grey[850],
              child: TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Поиск...',
                  hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: Colors.grey[500]),
                  filled: true,
                  fillColor: Colors.grey[800],
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          
          // Результаты поиска
          if (_isSearching && _searchResults.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              color: Colors.grey[850],
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final msg = _searchResults[index];
                  return ListTile(
                    dense: true,
                    title: Text(
                      msg.textContent,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _formatSearchDate(msg.createdAt),
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                    onTap: () => _scrollToMessage(msg),
                  );
                },
              ),
            ),
          
          if (_isSearching && _searchQuery.isNotEmpty && _searchResults.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.grey[850],
              child: Text('Ничего не найдено', style: TextStyle(color: Colors.grey[500])),
            ),

          // Прогресс загрузки
          if (_isUploading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.grey[850],
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Отправка: $_uploadingFileName',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: _uploadProgress,
                          backgroundColor: Colors.grey[700],
                          valueColor: AlwaysStoppedAnimation(Colors.blue[400]),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(_uploadProgress * 100).toInt()}%',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            ),
          
          // Список сообщений
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_outline, size: 48, color: Colors.grey[700]),
                        const SizedBox(height: 16),
                        Text('Сообщения зашифрованы', style: TextStyle(color: Colors.grey[500])),
                        const SizedBox(height: 8),
                        Text('Напишите первое сообщение', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                      ],
                    ),
                  )
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: messages.length + 1,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        cacheExtent: 500,
                        itemBuilder: (context, index) {
                          if (index == messages.length) {
                            if (chat.isLoadingMore(widget.userId)) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            } else if (!chat.hasMoreMessages(widget.userId)) {
                              return Padding(
                                padding: const EdgeInsets.all(16),
                                child: Center(
                                  child: Text(
                                    'Начало переписки',
                                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                                  ),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          }
                          
                          final message = messages[index];
                          final isMe = message.senderId == auth.userId;
                          final showDate = _shouldShowDateSeparator(messages, index);
                          final isRecent = DateTime.now().millisecondsSinceEpoch ~/ 1000 - message.createdAt < 3;

                          return Column(
                            children: [
                              if (showDate)
                                _buildDateSeparator(_formatDateSeparator(message.createdAt)),
                              AnimatedOpacity(
                                opacity: 1.0,
                                duration: Duration(milliseconds: isRecent ? 300 : 0),
                                curve: Curves.easeOut,
                                child: MessageBubble(
                                  message: message,
                                  isMe: isMe,
                                  onLongPress: () => _showMessageOptions(message.seqId, isMe),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      
                      // Кнопка "вниз"
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: AnimatedOpacity(
                          opacity: _showScrollToBottom ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: AnimatedScale(
                            scale: _showScrollToBottom ? 1.0 : 0.5,
                            duration: const Duration(milliseconds: 200),
                            child: IgnorePointer(
                              ignoring: !_showScrollToBottom,
                              child: FloatingActionButton.small(
                                backgroundColor: Colors.grey[700],
                                onPressed: _scrollToBottom,
                                child: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          
          // Поле ввода
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              border: Border(top: BorderSide(color: Colors.grey[800]!)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.attach_file,
                      color: _isUploading ? Colors.grey[600] : Colors.grey[400],
                    ),
                    onPressed: _isUploading ? null : _showAttachmentMenu,
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _handleKeyEvent,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 150),
                        child: TextField(
                          controller: _messageController,
                          focusNode: _focusNode,
                          style: const TextStyle(color: Colors.white),
                          maxLines: null,
                          minLines: 1,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          onChanged: _onTextChanged,
                          decoration: InputDecoration(
                            hintText: 'Сообщение...',
                            hintStyle: TextStyle(color: Colors.grey[500]),
                            filled: true,
                            fillColor: Colors.grey[800],
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: Colors.blue[600],
                    radius: 24,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}