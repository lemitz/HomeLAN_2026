// lib/screens/lock_screen.dart
import 'package:flutter/material.dart';

import '../services/biometric_service.dart';

/// Блокировка приложения (Android): биометрия или PIN устройства при запуске
/// и при каждом возвращении из фона.
///
/// Экран блокировки рисуется ПОВЕРХ приложения, поэтому все открытые
/// экраны и их состояние сохраняются, но ничего не видно и не нажимается.
class LockGate extends StatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  bool _locked = true;
  bool _authenticating = false;
  bool _obscured = false; // приложение в переключателе задач
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final suspended = BiometricService().isSuspended || _authenticating;
    switch (state) {
      case AppLifecycleState.inactive:
        if (!suspended) setState(() => _obscured = true);
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!suspended && !_locked) setState(() => _locked = true);
        break;
      case AppLifecycleState.resumed:
        setState(() => _obscured = false);
        if (_locked && !_authenticating) _unlock();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _message = null;
    });
    final result = await BiometricService().authenticate();
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      switch (result) {
        case UnlockResult.success:
          _locked = false;
          break;
        case UnlockResult.notAvailable:
          // На устройстве не настроена никакая блокировка — защищать нечем.
          _locked = false;
          break;
        case UnlockResult.failed:
          _message = 'Не удалось подтвердить личность';
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (_locked || _obscured) Positioned.fill(child: _buildOverlay(context)),
      ],
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Material(
      color: Colors.black,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.grey[900]!, Colors.black],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 80, color: Colors.blue[400]),
              const SizedBox(height: 24),
              const Text('HomeLAN', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 48),
              if (_locked && _authenticating)
                const CircularProgressIndicator()
              else if (_locked) ...[
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_message!, style: TextStyle(color: Colors.red[300])),
                  ),
                ElevatedButton.icon(
                  onPressed: _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Разблокировать'),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
