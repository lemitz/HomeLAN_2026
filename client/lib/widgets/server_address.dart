// lib/widgets/server_address.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/services.dart';

/// Применяет новый адрес сервера ко всем сервисам.
Future<String> applyServerUrl(BuildContext context, String input) async {
  final api = context.read<ApiService>();
  final ws = context.read<WebSocketService>();
  final url = await ServerConfig.save(input);
  api.baseUrl = url;
  ws.baseUrl = url;
  ConnectionService().init(url);
  await ConnectionService().tryReconnect();
  return url;
}

/// Поле редактирования адреса сервера (не требует Navigator).
class ServerAddressField extends StatefulWidget {
  final VoidCallback? onSaved;
  const ServerAddressField({super.key, this.onSaved});

  @override
  State<ServerAddressField> createState() => _ServerAddressFieldState();
}

class _ServerAddressFieldState extends State<ServerAddressField> {
  late final TextEditingController _controller;
  bool _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: context.read<ApiService>().baseUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final url = await applyServerUrl(context, _controller.text);
      if (!mounted) return;
      setState(() {
        _controller.text = url;
        _editing = false;
        _error = null;
      });
      widget.onSaved?.call();
    } catch (_) {
      setState(() => _error = 'Неверный адрес');
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = context.read<ApiService>().baseUrl;
    if (!_editing) {
      return TextButton.icon(
        onPressed: () => setState(() => _editing = true),
        icon: Icon(Icons.dns, size: 16, color: Colors.grey[500]),
        label: Text('Сервер: $current', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      );
    }
    return SizedBox(
      width: 360,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: '192.168.1.10:8080',
                errorText: _error,
                filled: true,
                fillColor: Colors.grey[850],
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          IconButton(icon: const Icon(Icons.check, color: Colors.green), onPressed: _save),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.grey),
            onPressed: () => setState(() {
              _editing = false;
              _controller.text = current;
            }),
          ),
        ],
      ),
    );
  }
}
