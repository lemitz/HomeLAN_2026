// lib/screens/new_device_link_screen.dart
//
// НОВОЕ устройство (без аккаунта): шаг 1 — показать QR#1 со своим
// эфемерным ключом, шаг 2 — получить QR#2 (или текст) с зашифрованным
// identity-ключом и кодом привязки.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/auth_provider.dart';
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
        hint: 'Отсканируйте QR-код с основного устройства', accept: (v) => LinkResponse.tryParse(v) != null);
    if (value != null) await _complete(value);
  }

  Future<void> _complete(String input) async {
    final resp = LinkResponse.tryParse(input);
    if (resp == null) {
      setState(() => _error = 'Это не ответ привязки. Скопируйте текст целиком (начинается с HL2:)');
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
    return Scaffold(
      appBar: AppBar(title: const Text('Привязать устройство')),
      body: _request == null || _completing
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                if (_completing) ...[
                  const SizedBox(height: 16),
                  Text('Привязка устройства...', style: TextStyle(color: Colors.grey[400])),
                ],
              ]),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(children: [_step1(), const SizedBox(height: 24), _step2()]),
                ),
              ),
            ),
    );
  }

  Widget _card({required List<Widget> children}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.grey[850], borderRadius: BorderRadius.circular(16)),
        child: Column(children: children),
      );

  Widget _step1() {
    final text = _request!.encode();
    return _card(children: [
      const Text('Шаг 1', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(
        'На основном устройстве откройте «Мои устройства» → «Добавить устройство» '
        'и отсканируйте этот код (или вставьте его текст).',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey[400]),
      ),
      const SizedBox(height: 16),
      Container(
        color: Colors.white,
        padding: const EdgeInsets.all(12),
        child: QrImageView(data: text, size: 220, backgroundColor: Colors.white),
      ),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
        },
        icon: const Icon(Icons.copy),
        label: const Text('Нет камеры? Скопировать как текст'),
      ),
      const SizedBox(height: 8),
      Text('Код сверки', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      Text(_verification!, style: const TextStyle(fontSize: 28, letterSpacing: 4, fontWeight: FontWeight.bold)),
      Text('Он должен совпасть с кодом на основном устройстве',
          style: TextStyle(color: Colors.grey[500], fontSize: 12)),
    ]);
  }

  Widget _step2() {
    return _card(children: [
      const Text('Шаг 2', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('Получите ответ с основного устройства.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[400])),
      const SizedBox(height: 16),
      if (canScanQr)
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Сканировать ответ'),
          ),
        ),
      const SizedBox(height: 12),
      TextField(
        controller: _responseController,
        minLines: 2,
        maxLines: 4,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        decoration: InputDecoration(
          hintText: 'Или вставьте текст ответа (HL2:...)',
          filled: true,
          fillColor: Colors.grey[800],
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        height: 48,
        child: OutlinedButton(
          onPressed: () => _complete(_responseController.text),
          child: const Text('Привязать'),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
      ],
    ]);
  }
}
