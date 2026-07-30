// lib/screens/link_device_screen.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/auth_provider.dart';
import '../main.dart';

class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key});

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  String? _linkCode;
  String? _exportedKey;
  bool _isLoading = false;
  bool _isScanning = false;
  String? _error;

  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _generateCode();
  }

  Future<void> _generateCode() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final authProvider = context.read<AuthProvider>();
      
      // Получаем код привязки с сервера
      final result = await authProvider.apiService.createLinkCode(
        userId: authProvider.userId!,
      );

      // Экспортируем ключ для передачи на новое устройство
      final exportedKey = await cryptoService.exportKeyPair();

      setState(() {
        _linkCode = result['link_code'];
        _exportedKey = exportedKey;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _copyCode() {
    if (_linkCode != null) {
      Clipboard.setData(ClipboardData(text: _linkCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код скопирован')),
      );
    }
  }

  void _copyFullData() {
    if (_linkCode != null && _exportedKey != null) {
      final fullData = '$_linkCode:$_exportedKey';
      Clipboard.setData(ClipboardData(text: fullData));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код и ключ скопированы')),
      );
    }
  }

  String _getQrData() {
    return jsonEncode({
      'type': 'link_code',
      'code': _linkCode,
      'key': _exportedKey,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[850],
        title: const Text('Добавить устройство', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _linkCode != null
              ? _buildShowCode()
              : _buildError(),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 80, color: Colors.red[400]),
          const SizedBox(height: 24),
          const Text(
            'Ошибка создания кода',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Colors.grey[400]),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _generateCode,
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
  }

  Widget _buildShowCode() {
    final qrData = _getQrData();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Инструкция
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(Icons.devices, size: 48, color: Colors.blue[400]),
                const SizedBox(height: 16),
                const Text(
                  'Привязка нового устройства',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '1. Откройте приложение на новом устройстве\n'
                  '2. Нажмите "Привязать к аккаунту"\n'
                  '3. Отсканируйте QR-код ниже',
                  style: TextStyle(color: Colors.grey[400], fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // QR-код с кодом И ключом
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.qr_code_2, size: 24, color: Colors.green[400]),
                    const SizedBox(width: 8),
                    const Text(
                      'QR содержит код + ключ шифрования',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: qrData,
                    size: 250,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '🔐 Ключ шифрования включён в QR',
                  style: TextStyle(color: Colors.green[400], fontSize: 12),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Текстовый код (только код, без ключа - для ручного ввода)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(Icons.keyboard, size: 32, color: Colors.orange[400]),
                const SizedBox(height: 12),
                const Text(
                  'Нет камеры? Код для ввода:',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[700],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _linkCode!,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 3,
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: _copyCode,
                      icon: Icon(Icons.copy, color: Colors.blue[400]),
                      tooltip: 'Копировать код',
                      iconSize: 28,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '⚠️ При ручном вводе ключ передастся отдельно',
                  style: TextStyle(color: Colors.orange[400], fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _copyFullData,
                  icon: const Icon(Icons.vpn_key, size: 16),
                  label: const Text('Копировать код + ключ'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange[400],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '⏱ Код действителен 5 минут',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Кнопки внизу
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _generateCode,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Новый код'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(color: Colors.grey[600]!),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.green[600],
                  ),
                  child: const Text('Готово', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}