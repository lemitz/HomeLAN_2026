import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../version.dart';
import 'devices_screen.dart';
import 'safety_number_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _showColorPicker(String title, int currentColor, Function(int) onSelect) {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.purple,
      Colors.orange,
      Colors.red,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
      Colors.amber,
      Colors.grey[800]!,
      Colors.grey[700]!,
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: colors
              .map((color) => GestureDetector(
                    onTap: () {
                      onSelect(color.toARGB32());
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: currentColor == color.toARGB32() ? Border.all(color: Colors.white, width: 3) : null,
                      ),
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _showE2EWarning() {
    final phrases = [
      'Ты чё, дурак? 🤡',
      'Хорошая попытка, но нет 😏',
      'Шифрование — это не опция, это образ жизни 🔐',
      'Даже не думай об этом 🙅',
      'КГБ уже выехал... шучу, но E2E остаётся 😎',
      'Нет. Просто нет. ❌',
      'Ты серьёзно? 🤦',
      'Это кнопка-ловушка 🪤',
      'Может тебе ещё пароль 1234 поставить? 🤔',
      'Отключить шифрование = отправить нюдсы в интернет 📸',
    ];

    final random = phrases[DateTime.now().millisecond % phrases.length];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange[400]),
            const SizedBox(width: 12),
            const Text('Эй!', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          random,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green[600]),
            child: const Text('Ладно, понял 😅', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: Row(
          children: [
            Icon(Icons.lock, color: Colors.green[400]),
            const SizedBox(width: 12),
            const Text('HomeLAN', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Версия $appVersion (протокол v$protocolVersion)',
              style: TextStyle(color: Colors.grey[300], fontSize: 16),
            ),
            const SizedBox(height: 16),
            Text(
              'Приватный мессенджер для домашней сети',
              style: TextStyle(color: Colors.grey[400]),
            ),
            const SizedBox(height: 12),
            _buildInfoRow(Icons.security, 'E2E', 'X25519 + HKDF + XChaCha20-Poly1305'),
            _buildInfoRow(Icons.storage, 'Сервер', 'SQLCipher + USB-ключ'),
            _buildInfoRow(Icons.phone_android, 'Клиент', 'кеш только шифротекстов'),
            _buildInfoRow(Icons.devices, 'Платформы', 'Windows, Android'),
            const SizedBox(height: 16),
            Text(
              '© 2026 HomeLAN Project',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Закрыть', style: TextStyle(color: Colors.blue[400])),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey[500]),
          const SizedBox(width: 8),
          Text('$title: ', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          Flexible(
            child: Text(
              value,
              style: TextStyle(color: Colors.grey[300], fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[850],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Настройки',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),

          // Профиль
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.blue[700],
                  child: Text(
                    auth.username?.isNotEmpty == true ? auth.username![0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.username ?? 'Unknown',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${auth.userId ?? '-'}',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 14,
                        ),
                      ),
                      if (auth.isAdmin)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange[700],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'ADMIN',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Устройства
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'УСТРОЙСТВА',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(children: [
              ListTile(
                leading: Icon(Icons.devices, color: Colors.blue[400]),
                title: const Text('Мои устройства', style: TextStyle(color: Colors.white)),
                subtitle: Text('Управление привязанными устройствами', style: TextStyle(color: Colors.grey[500])),
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DevicesScreen()),
                  );
                },
              ),
              if (auth.hasPartner) ...[
                Divider(color: Colors.grey[800], height: 1),
                ListTile(
                  leading: Icon(Icons.fingerprint, color: Colors.green[400]),
                  title: const Text('Отпечаток ключей', style: TextStyle(color: Colors.white)),
                  subtitle:
                      Text('Сверка с собеседником (защита от подмены)', style: TextStyle(color: Colors.grey[500])),
                  trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SafetyNumberScreen())),
                ),
              ],
            ]),
          ),

          const SizedBox(height: 24),

          // Безопасность и Уведомления
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'БЕЗОПАСНОСТЬ И УВЕДОМЛЕНИЯ',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Consumer<ChatProvider>(
                  builder: (context, chat, _) => ListTile(
                    leading: Icon(
                      chat.notificationsEnabled ? Icons.notifications_active : Icons.notifications_off,
                      color: chat.notificationsEnabled ? Colors.blue[400] : Colors.grey[600],
                    ),
                    title: const Text('Уведомления', style: TextStyle(color: Colors.white)),
                    subtitle: Text(
                      chat.notificationsEnabled ? 'Включены' : 'Выключены',
                      style: TextStyle(color: Colors.grey[500]),
                    ),
                    trailing: Switch(
                      value: chat.notificationsEnabled,
                      activeThumbColor: Colors.blue[400],
                      onChanged: (value) => chat.setNotificationsEnabled(value),
                    ),
                  ),
                ),
                Divider(color: Colors.grey[800], height: 1),
                ListTile(
                  leading: Icon(Icons.lock, color: Colors.green[400]),
                  title: const Text('Сквозное шифрование', style: TextStyle(color: Colors.white)),
                  subtitle: Text('X25519 + XChaCha20-Poly1305', style: TextStyle(color: Colors.grey[500])),
                  trailing: Switch(
                    value: true,
                    activeThumbColor: Colors.green[400],
                    onChanged: (value) {
                      if (!value) {
                        _showE2EWarning();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Инфо
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'ИНФОРМАЦИЯ',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: Icon(Icons.smartphone, color: Colors.grey[400]),
              title: const Text(
                'Device ID',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                auth.deviceId ?? '-',
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Внешний вид
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'ВНЕШНИЙ ВИД',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Consumer<ChatProvider>(
              builder: (context, chat, _) => Column(
                children: [
                  ListTile(
                    leading: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(chat.myBubbleColor),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                    title: const Text('Мои сообщения', style: TextStyle(color: Colors.white)),
                    subtitle: Text('Цвет баблов', style: TextStyle(color: Colors.grey[500])),
                    onTap: () => _showColorPicker(
                      'Цвет моих сообщений',
                      chat.myBubbleColor,
                      chat.setMyBubbleColor,
                    ),
                  ),
                  Divider(color: Colors.grey[800], height: 1),
                  ListTile(
                    leading: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(chat.otherBubbleColor),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                    title: const Text('Входящие сообщения', style: TextStyle(color: Colors.white)),
                    subtitle: Text('Цвет баблов', style: TextStyle(color: Colors.grey[500])),
                    onTap: () => _showColorPicker(
                      'Цвет входящих сообщений',
                      chat.otherBubbleColor,
                      chat.setOtherBubbleColor,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Действия
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'ДЕЙСТВИЯ',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.orange),
                  title: const Text(
                    'Выйти',
                    style: TextStyle(color: Colors.orange),
                  ),
                  subtitle: Text(
                    'Ключ шифрования останется на устройстве',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  onTap: () => _showLogoutDialog(context, auth),
                ),
                Divider(color: Colors.grey[800], height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.red),
                  title: const Text(
                    'Полная очистка',
                    style: TextStyle(color: Colors.red),
                  ),
                  subtitle: Text(
                    'Удалить ключи и отвязать устройство',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  onTap: () => _showFullWipeDialog(context, auth),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red[900]?.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red[700]!, width: 1),
            ),
            child: Row(
              children: [
                Icon(Icons.warning, color: Colors.red[400], size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Полная очистка удалит ключ шифрования и отвяжет устройство. Вернуть доступ можно только новой привязкой с другого вашего устройства. Если это ваше единственное устройство — история станет нечитаемой навсегда.',
                    style: TextStyle(
                      color: Colors.red[300],
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Divider(color: Colors.grey),
          ),

          ListTile(
            leading: Icon(Icons.info_outline, color: Colors.grey[400]),
            title: const Text('О приложении', style: TextStyle(color: Colors.white)),
            subtitle:
                Text('Версия $appVersion (протокол v$protocolVersion)', style: TextStyle(color: Colors.grey[500])),
            onTap: _showAboutDialog,
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, AuthProvider auth) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Выход', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Сессия на этом устройстве будет закрыта, локальный кеш сообщений очищен.\n\nКлюч шифрования останется — после входа по паролю история снова загрузится с сервера.',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена', style: TextStyle(color: Colors.grey[400])),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Выйти', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      // Корневой экран сам переключится на вход — просто закрываем всё поверх него.
      Navigator.of(context).popUntil((route) => route.isFirst);
      await auth.logout();
    }
  }

  void _showFullWipeDialog(BuildContext context, AuthProvider auth) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.red[400]),
            const SizedBox(width: 8),
            const Text('Полная очистка', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Это действие удалит:', style: TextStyle(color: Colors.white)),
            const SizedBox(height: 12),
            _buildWipeItem('Ключ шифрования'),
            _buildWipeItem('Привязку этого устройства'),
            _buildWipeItem('Локальный кеш и настройки'),
            const SizedBox(height: 16),
            Text(
              'Восстановление невозможно!',
              style: TextStyle(color: Colors.red[400], fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена', style: TextStyle(color: Colors.grey[400])),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('УДАЛИТЬ ВСЁ', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[850],
          content: const Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Удаление данных...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );

      final navigator = Navigator.of(context);
      await auth.fullWipe();
      navigator.popUntil((route) => route.isFirst);
    }
  }

  Widget _buildWipeItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.remove_circle, color: Colors.red[400], size: 16),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: Colors.grey[300])),
        ],
      ),
    );
  }
}
