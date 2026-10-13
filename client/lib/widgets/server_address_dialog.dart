// lib/widgets/server_address_dialog.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/server_config.dart';
import '../utils/server_url.dart';

/// Диалог ввода адреса сервера. Возвращает true, если адрес был сохранён.
class ServerAddressDialog extends StatefulWidget {
  const ServerAddressDialog({super.key});

  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const ServerAddressDialog(),
    );
    return result ?? false;
  }

  @override
  State<ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<ServerAddressDialog> {
  late final TextEditingController _controller;
  String? _status;
  bool _statusOk = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: displayServerUrl(ServerConfig().current),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _busy = true;
      _status = 'Поиск сервера в сети (mDNS)...';
      _statusOk = false;
    });
    final found = await ServerConfig().discover();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (found != null) {
        _controller.text = displayServerUrl(found);
        _status = 'Найден: ${displayServerUrl(found)}';
        _statusOk = true;
      } else {
        _status = 'Сервер не найден. Введите адрес вручную '
            '(его показывает сервер при запуске).';
        _statusOk = false;
      }
    });
  }

  Future<void> _check() async {
    final normalized = normalizeServerUrl(_controller.text);
    if (normalized == null) {
      setState(() {
        _status = 'Некорректный адрес';
        _statusOk = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Проверка $normalized ...';
    });
    final ok = await ServerConfig().check(normalized);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = ok ? 'Сервер отвечает ✅' : 'Сервер не отвечает по этому адресу';
      _statusOk = ok;
    });
  }

  Future<void> _save() async {
    final normalized = normalizeServerUrl(_controller.text);
    if (normalized == null) {
      setState(() {
        _status = 'Некорректный адрес. Пример: 192.168.1.10:8080';
        _statusOk = false;
      });
      return;
    }

    setState(() => _busy = true);
    await ServerConfig().apply(normalized);

    // Если пользователь уже вошёл — переподключаемся по новому адресу
    if (mounted) {
      try {
        await context.read<AuthProvider>().onServerUrlChanged();
      } catch (_) {
        // Провайдера может не быть над этим контекстом — это нормально
      }
    }

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.grey[850],
      title: const Text('Адрес сервера', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            enabled: !_busy,
            autofocus: true,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'IP или имя хоста[:порт]',
              hintText: '192.168.1.10:8080',
              labelStyle: TextStyle(color: Colors.grey[400]),
              hintStyle: TextStyle(color: Colors.grey[600]),
              prefixIcon: Icon(Icons.dns, color: Colors.grey[400]),
              filled: true,
              fillColor: Colors.grey[900],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _discover,
                icon: const Icon(Icons.wifi_find, size: 18),
                label: const Text('Найти в сети'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _check,
                icon: const Icon(Icons.network_check, size: 18),
                label: const Text('Проверить'),
              ),
            ],
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Expanded(
                  child: Text(
                    _status!,
                    style: TextStyle(
                      fontSize: 13,
                      color: _statusOk ? Colors.green[400] : Colors.grey[400],
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Адрес не меняется автоматически: клиент будет использовать только '
            'указанный здесь сервер.',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Компактная строка «Сервер: host:port ✎» для экрана входа и экрана ожидания.
class ServerAddressRow extends StatelessWidget {
  final Color? color;

  const ServerAddressRow({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ServerConfig().url,
      builder: (context, url, _) {
        final configured = ServerConfig().isConfigured;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => ServerAddressDialog.show(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  configured ? Icons.dns : Icons.warning_amber_rounded,
                  size: 16,
                  color: configured ? (color ?? Colors.grey[500]) : Colors.orange[400],
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    configured
                        ? 'Сервер: ${displayServerUrl(url)}'
                        : 'Сервер не настроен — нажмите, чтобы указать адрес',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: configured ? (color ?? Colors.grey[500]) : Colors.orange[400],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.edit, size: 14, color: color ?? Colors.grey[600]),
              ],
            ),
          ),
        );
      },
    );
  }
}
