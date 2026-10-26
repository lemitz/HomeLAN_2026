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

import '../providers/auth_provider.dart';
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
        hint: 'Отсканируйте QR-код на новом устройстве', accept: (v) => LinkRequest.tryParse(v) != null);
    if (value != null) await _accept(value);
  }

  Future<void> _accept(String input) async {
    final req = LinkRequest.tryParse(input);
    if (req == null) {
      setState(() => _error = 'Это не запрос привязки. Скопируйте текст целиком (начинается с HL1:)');
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
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (DateTime.now().isAfter(_expiresAt!)) {
          _ticker?.cancel();
          setState(() => _response = null);
        } else {
          setState(() {});
        }
      });
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.userMessage;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is NetworkException ? 'Сервер недоступен' : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Добавить устройство')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _busy
                ? const Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator())
                : _response != null
                    ? _buildResponse()
                    : _request != null
                        ? _buildConfirm()
                        : _buildInput(),
          ),
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.grey[850], borderRadius: BorderRadius.circular(16)),
        child: Column(children: children),
      );

  Widget _errorText() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
        );

  Widget _buildInput() {
    return _card([
      Icon(Icons.add_to_home_screen, size: 48, color: Colors.blue[400]),
      const SizedBox(height: 12),
      Text(
        'На новом устройстве нажмите «Привязать к аккаунту». '
        'Отсканируйте показанный там код или вставьте его текст.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey[400]),
      ),
      const SizedBox(height: 16),
      if (canScanQr)
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
              onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Сканировать')),
        ),
      const SizedBox(height: 12),
      TextField(
        controller: _requestController,
        minLines: 2,
        maxLines: 4,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        decoration: InputDecoration(
          hintText: 'Или вставьте текст запроса (HL1:...)',
          filled: true,
          fillColor: Colors.grey[800],
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        height: 48,
        child: OutlinedButton(onPressed: () => _accept(_requestController.text), child: const Text('Продолжить')),
      ),
      _errorText(),
    ]);
  }

  Widget _buildConfirm() {
    final req = _request!;
    return _card([
      const Text('Подтвердите устройство', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      ListTile(
        leading: Icon(req.deviceType == 'android' ? Icons.phone_android : Icons.computer),
        title: Text(req.deviceName.isEmpty ? req.deviceType : req.deviceName),
        subtitle: Text(req.deviceType),
      ),
      const SizedBox(height: 8),
      Text('Код сверки', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      Text(_verification!, style: const TextStyle(fontSize: 28, letterSpacing: 4, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('Убедитесь, что на новом устройстве показан ТОТ ЖЕ код.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.orange[300])),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() {
              _request = null;
              _verification = null;
            }),
            child: const Text('Не совпадает'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: ElevatedButton(onPressed: _confirm, child: const Text('Коды совпадают'))),
      ]),
      _errorText(),
    ]);
  }

  Widget _buildResponse() {
    final left = _expiresAt!.difference(DateTime.now());
    final mm = left.inMinutes.toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return _card([
      const Text('Покажите этот код новому устройству', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      Container(
        color: Colors.white,
        padding: const EdgeInsets.all(12),
        child: QrImageView(data: _response!, size: 240, backgroundColor: Colors.white),
      ),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: _response!));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
        },
        icon: const Icon(Icons.copy),
        label: const Text('Нет камеры? Скопировать как текст'),
      ),
      Text('Ключ зашифрован для выбранного устройства — другим он бесполезен.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      const SizedBox(height: 8),
      Text('Действует ещё $mm:$ss', style: TextStyle(color: Colors.grey[400])),
      const SizedBox(height: 16),
      ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Готово')),
    ]);
  }
}
