// lib/widgets/server_address.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/services.dart';
import '../theme.dart';

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
      setState(() => _error = S.of(context).invalidAddress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = context.read<ApiService>().baseUrl;
    return AnimatedSwitcher(
      duration: kFast,
      child: !_editing
          ? TextButton.icon(
              key: const ValueKey('view'),
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.dns_outlined, size: 16, color: AppColors.muted),
              label: Text(current.replaceFirst(RegExp(r'^https?://'), ''),
                  style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            )
          : SizedBox(
              key: const ValueKey('edit'),
              width: 360,
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '192.168.1.10:8080',
                      errorText: _error,
                      prefixIcon: const Icon(Icons.dns_outlined, size: 18),
                    ),
                    onSubmitted: (_) => _save(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.check, color: AppColors.success), onPressed: _save),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _editing = false;
                    _error = null;
                    _controller.text = current;
                  }),
                ),
              ]),
            ),
    );
  }
}
