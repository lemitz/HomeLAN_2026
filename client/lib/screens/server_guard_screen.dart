// lib/screens/server_guard_screen.dart
import 'package:flutter/material.dart';

import '../services/connection_service.dart';
import '../l10n/strings.dart';
import '../theme.dart';
import '../widgets/server_address.dart';
import '../widgets/ui.dart';

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
    final s = S.current;
    final down = _conn.isDisconnected;
    return FadeSlideIn(
      offsetY: 0,
      child: Material(
        color: AppColors.bg,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const AppLogo(size: 72),
            const SizedBox(height: 28),
            AnimatedSwitcher(
              duration: kFast,
              child: Text(
                down ? s.serverUnavailable : s.connecting,
                key: ValueKey(down),
                style: TextStyle(fontSize: 16, color: down ? AppColors.danger : AppColors.muted),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 52,
              child: AnimatedSwitcher(
                duration: kFast,
                child: !down || _retrying
                    ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(s.reconnect),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            const ServerAddressField(),
          ]),
        ),
      ),
    );
  }
}
