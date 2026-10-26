// lib/screens/server_guard_screen.dart
import 'package:flutter/material.dart';

import '../services/connection_service.dart';
import '../widgets/server_address.dart';

/// Windows: пока сервер недоступен, содержимое приложения скрыто
/// (решение v0.9 — переписка на ПК видна только при связи с домашним сервером).
/// Экран рисуется поверх приложения и не сбрасывает его состояние.
class ServerGuard extends StatefulWidget {
  final Widget child;
  const ServerGuard({super.key, required this.child});

  @override
  State<ServerGuard> createState() => _ServerGuardState();
}

class _ServerGuardState extends State<ServerGuard> {
  final _conn = ConnectionService();
  bool _retrying = false;
  // Свой Overlay нужен полю ввода адреса: мы находимся выше Navigator.
  // Запись пересоздаётся при каждом появлении экрана.
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    _conn.addListener(_refresh);
    _conn.startMonitoring();
  }

  @override
  void dispose() {
    _conn.removeListener(_refresh);
    _conn.stopMonitoring();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    if (_entry?.mounted == true) _entry!.markNeedsBuild();
  }

  Future<void> _retry() async {
    if (_retrying) return;
    _retrying = true;
    _refresh();
    await _conn.tryReconnect();
    _retrying = false;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final show = !_conn.isConnected;
    if (show) {
      _entry ??= OverlayEntry(builder: (_) => _buildOverlay());
    } else {
      _entry = null;
    }
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (show) Positioned.fill(child: Overlay(key: ObjectKey(_entry), initialEntries: [_entry!])),
      ],
    );
  }

  Widget _buildOverlay() {
    final down = _conn.isDisconnected;
    return Material(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(down ? Icons.cloud_off : Icons.cloud_sync, size: 80, color: down ? Colors.red[400] : Colors.blue[400]),
            const SizedBox(height: 24),
            const Text('HomeLAN', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 16),
            Text(down ? 'Сервер недоступен' : 'Подключение...',
                style: TextStyle(fontSize: 16, color: down ? Colors.red[400] : Colors.blue[400])),
            if (down && _conn.disconnectReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_conn.disconnectReason!, style: TextStyle(color: Colors.grey[500])),
              ),
            const SizedBox(height: 32),
            if (!down || _retrying)
              const CircularProgressIndicator()
            else
              ElevatedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Переподключиться'),
              ),
            const SizedBox(height: 24),
            const ServerAddressField(),
          ],
        ),
      ),
    );
  }
}
