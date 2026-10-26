// lib/screens/link_device_screen.dart
//
// ОСНОВНОЕ устройство (авторизовано): получает QR#1 нового устройства,
// после сверки кода создаёт код привязки и показывает QR#2 с
// identity-ключом, зашифрованным эфемерным ключом нового устройства.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/strings.dart';
import '../providers/auth_provider.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../services/services.dart';
import '../widgets/qr_scan_view.dart';

class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key});

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  final _requestController = TextEditingController();
  LinkRequest? _request;
  String? _verification;
  String? _response;
  DateTime? _expiresAt;
  Timer? _ticker;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _requestController.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    final value = await QrScanPage.open(context,
        hint: S.of(context).scanFromNewDevice, accept: (v) => LinkRequest.tryParse(v) != null);
    if (value != null) await _accept(value);
  }

  Future<void> _accept(String input) async {
    final req = LinkRequest.tryParse(input);
    if (req == null) {
      setState(() => _error = S.of(context).notLinkRequest);
      return;
    }
    final code = await LinkCrypto.verificationCode(req.ephemeralPublic);
    if (!mounted) return;
    setState(() {
      _request = req;
      _verification = code;
      _error = null;
    });
  }

  Future<void> _confirm() async {
    final req = _request!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = context.read<AuthProvider>();
      final data = await auth.api.createLinkCode(
        deviceId: req.deviceId,
        deviceName: req.deviceName,
        deviceType: req.deviceType,
      );
      final code = data['link_code'] as String;
      final identity = await auth.crypto.exportIdentityPrivate();
      final (ephPub, ct) = await LinkCrypto.seal(
        identityPrivate: identity,
        newDevicePublic: req.ephemeralPublic,
        deviceId: req.deviceId,
        code: code,
      );
      identity.fillRange(0, identity.length, 0);
      if (!mounted) return;
      setState(() {
        _response = LinkResponse(code: code, ephemeralPublic: ephPub, ciphertext: ct).encode();
        _expiresAt = DateTime.fromMillisecondsSinceEpoch((data['expires_at'] as int) * 1000);
        _busy = false;
      });
      // Экран целиком перестраивается только при истечении кода;
      // обратный отсчёт тикает в отдельном маленьком виджете.
      _ticker = Timer(_expiresAt!.difference(DateTime.now()), () {
        if (mounted) setState(() => _response = null);
      });
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.userMessage;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is NetworkException ? S.current.serverUnavailable : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final Widget body = _busy
        ? const Padding(key: ValueKey('busy'), padding: EdgeInsets.all(48), child: CircularProgressIndicator())
        : _response != null
            ? KeyedSubtree(key: const ValueKey('resp'), child: _buildResponse(s))
            : _request != null
                ? KeyedSubtree(key: const ValueKey('confirm'), child: _buildConfirm(s))
                : KeyedSubtree(key: const ValueKey('input'), child: _buildInput(s));
    return Scaffold(
      appBar: AppBar(title: Text(s.addDevice)),
      body: NarrowBody(
        maxWidth: 480,
        child: AnimatedSwitcher(
          duration: kMedium,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
                position: Tween(begin: const Offset(0.05, 0), end: Offset.zero).animate(a), child: child),
          ),
          child: body,
        ),
      ),
    );
  }

  Widget _errorText() => AnimatedSize(
        duration: kFast,
        child: _error == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: AppColors.danger), textAlign: TextAlign.center),
              ),
      );

  Widget _buildInput(S s) {
    return Panel(
      child: Column(children: [
        const Icon(Icons.add_to_home_screen, size: 44, color: AppColors.accent),
        const SizedBox(height: 12),
        Text(s.addDeviceHint, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 20),
        if (canScanQr) ...[
          PrimaryButton(icon: Icons.qr_code_scanner, label: s.scan, onPressed: _scan),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _requestController,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: s.pasteRequest),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: () => _accept(_requestController.text), child: Text(s.next)),
        _errorText(),
      ]),
    );
  }

  Widget _buildConfirm(S s) {
    final req = _request!;
    return Panel(
      child: Column(children: [
        Text(s.confirmDevice, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(req.deviceType == 'android' ? Icons.phone_android : Icons.desktop_windows_outlined, size: 32),
          title: Text(req.deviceName.isEmpty ? req.deviceType : req.deviceName),
          subtitle: Text(req.deviceType, style: const TextStyle(color: AppColors.muted)),
        ),
        const SizedBox(height: 8),
        Text(s.verificationCode, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        const SizedBox(height: 4),
        Text(_verification!, style: const TextStyle(fontSize: 30, letterSpacing: 6, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(s.codesMustMatch, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.warning)),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() {
                _request = null;
                _verification = null;
              }),
              child: Text(s.codesDiffer),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: _confirm, child: Text(s.codesMatch))),
        ]),
        _errorText(),
      ]),
    );
  }

  Widget _buildResponse(S s) {
    return Panel(
      child: Column(children: [
        Text(s.showToNewDevice, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(data: _response!, size: 240, backgroundColor: Colors.white),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _response!));
            showSnack(context, s.copied);
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(s.copyAsText),
        ),
        _Countdown(until: _expiresAt!),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.done)),
      ]),
    );
  }
}

class _Countdown extends StatefulWidget {
  final DateTime until;
  const _Countdown({required this.until});

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _t;
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.until.difference(DateTime.now());
    final secs = left.isNegative ? 0 : left.inSeconds;
    final mmss = '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
    return Text(S.of(context).validFor(mmss),
        style: const TextStyle(color: AppColors.muted, fontFeatures: [FontFeature.tabularFigures()]));
  }
}
