// lib/screens/new_device_link_screen.dart
//
// НОВОЕ устройство (без аккаунта): шаг 1 — показать QR#1 со своим
// эфемерным ключом, шаг 2 — получить QR#2 (или текст) с зашифрованным
// identity-ключом и кодом привязки.
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

class NewDeviceLinkScreen extends StatefulWidget {
  const NewDeviceLinkScreen({super.key});

  @override
  State<NewDeviceLinkScreen> createState() => _NewDeviceLinkScreenState();
}

class _NewDeviceLinkScreenState extends State<NewDeviceLinkScreen> {
  final _responseController = TextEditingController();
  EphemeralKey? _ephemeral;
  LinkRequest? _request;
  String? _verification;
  bool _completing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _responseController.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final eph = await EphemeralKey.generate();
    final req = LinkRequest(
      deviceId: DeviceInfo.newDeviceId(),
      deviceName: DeviceInfo.name(),
      deviceType: DeviceInfo.type(),
      ephemeralPublic: eph.publicKey,
    );
    final code = await LinkCrypto.verificationCode(eph.publicKey);
    if (!mounted) return;
    setState(() {
      _ephemeral = eph;
      _request = req;
      _verification = code;
    });
  }

  Future<void> _scan() async {
    final value = await QrScanPage.open(context,
        hint: S.of(context).scanFromMainDevice, accept: (v) => LinkResponse.tryParse(v) != null);
    if (value != null) await _complete(value);
  }

  Future<void> _complete(String input) async {
    final resp = LinkResponse.tryParse(input);
    if (resp == null) {
      setState(() => _error = S.of(context).notLinkResponse);
      return;
    }
    setState(() {
      _completing = true;
      _error = null;
    });
    try {
      final identity = await LinkCrypto.open(
        ephemeralPrivate: _ephemeral!.privateKey,
        oldDevicePublic: resp.ephemeralPublic,
        ciphertext: resp.ciphertext,
        deviceId: _request!.deviceId,
        code: resp.code,
      );
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      final ok = await auth.completeLinking(
        deviceId: _request!.deviceId,
        linkCode: resp.code,
        identityPrivate: identity,
      );
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      } else {
        setState(() {
          _completing = false;
          _error = auth.error;
        });
      }
    } on CryptoException catch (e) {
      setState(() {
        _completing = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final Widget body = _request == null || _completing
        ? Center(
            key: const ValueKey('busy'),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              if (_completing) ...[
                const SizedBox(height: 16),
                Text(s.linking, style: const TextStyle(color: AppColors.muted)),
              ],
            ]),
          )
        : NarrowBody(
            key: const ValueKey('form'),
            maxWidth: 480,
            child: Column(children: [
              FadeSlideIn(child: _step1(s)),
              const SizedBox(height: 16),
              FadeSlideIn(delay: const Duration(milliseconds: 60), child: _step2(s)),
            ]),
          );
    return Scaffold(
      appBar: AppBar(title: Text(s.linkTitle)),
      body: AnimatedSwitcher(duration: kMedium, child: body),
    );
  }

  Widget _stepHeader(int n, String text) => Row(children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
          child: Text('$n', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w500))),
      ]);

  Widget _step1(S s) {
    final text = _request!.encode();
    return Panel(
      child: Column(children: [
        _stepHeader(1, s.linkStep1),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(data: text, size: 220, backgroundColor: Colors.white),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            showSnack(context, s.copied);
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(s.copyAsText),
        ),
        const SizedBox(height: 8),
        Text(s.verificationCode, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        const SizedBox(height: 4),
        Text(_verification!, style: const TextStyle(fontSize: 30, letterSpacing: 6, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _step2(S s) {
    return Panel(
      child: Column(children: [
        _stepHeader(2, s.linkStep2),
        const SizedBox(height: 16),
        if (canScanQr) ...[
          PrimaryButton(icon: Icons.qr_code_scanner, label: s.scan, onPressed: _scan),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _responseController,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: s.pasteResponse),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: () => _complete(_responseController.text), child: Text(s.link)),
        AnimatedSize(
          duration: kFast,
          child: _error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: const TextStyle(color: AppColors.danger), textAlign: TextAlign.center),
                ),
        ),
      ]),
    );
  }
}
