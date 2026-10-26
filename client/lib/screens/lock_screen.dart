// lib/screens/lock_screen.dart
import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/biometric_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

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
          _message = S.current.unlockFailed;
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final show = _locked || _obscured;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        // Закрывается мгновенно (безопасность), открывается плавно.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !show,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: show ? Duration.zero : kMedium,
              curve: Curves.easeOutCubic,
              child: _buildOverlay(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final s = S.of(context);
    return Material(
      color: AppColors.bg,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const AppLogo(size: 72),
          const SizedBox(height: 40),
          SizedBox(
            height: 56,
            child: AnimatedSwitcher(
              duration: kFast,
              child: !_locked
                  ? const SizedBox.shrink()
                  : _authenticating
                      ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : IconButton.filled(
                          key: const ValueKey('unlock'),
                          iconSize: 32,
                          tooltip: s.unlock,
                          onPressed: _unlock,
                          icon: const Icon(Icons.fingerprint),
                        ),
            ),
          ),
          AnimatedSize(
            duration: kFast,
            child: _message == null || !_locked
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_message!, style: const TextStyle(color: AppColors.danger)),
                  ),
          ),
        ]),
      ),
    );
  }
}
