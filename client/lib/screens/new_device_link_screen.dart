// lib/screens/new_device_link_screen.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/services.dart';
import '../providers/auth_provider.dart';
import '../main.dart';

class NewDeviceLinkScreen extends StatefulWidget {
  const NewDeviceLinkScreen({super.key});

  @override
  State<NewDeviceLinkScreen> createState() => _NewDeviceLinkScreenState();
}

class _NewDeviceLinkScreenState extends State<NewDeviceLinkScreen> {
  String? _deviceId;
  bool _isScanning = false;
  bool _isCompleting = false;
  String? _error;
  
  final _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _generateDeviceInfo();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _generateDeviceInfo() {
    _deviceId = LinkingService.generateDeviceId();
  }

  String _getDeviceName() {
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isAndroid) return 'Android Phone';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isLinux) return 'Linux PC';
    return 'Device';
  }

  Future<void> _onCodeScanned(String data) async {
    if (_isCompleting) return;

    try {
      final qrData = jsonDecode(data);
      if (qrData['type'] == 'link_code') {
        final code = qrData['code'] as String;
        final key = qrData['key'] as String?;
        await _completeLink(code, importedKey: key);
      }
    } catch (e) {
      _showError('Неверный QR-код');
    }
  }

  Future<void> _completeLink(String code, {String? importedKey}) async {
    setState(() {
      _isCompleting = true;
      _isScanning = false;
      _error = null;
    });

    try {
      // Если есть импортированный ключ — используем его
      if (importedKey != null && importedKey.isNotEmpty) {
        await cryptoService.importKeyPair(importedKey);
        print('🔐 Imported key from QR code');
      }
      
      // Получаем публичный ключ (свой или импортированный)
      final publicKey = await cryptoService.getPublicKey();
      
      // Завершаем привязку
      final result = await apiService.completeLinking(
        linkCode: code,
        deviceId: _deviceId!,
        deviceName: _getDeviceName(),
        deviceType: Platform.operatingSystem,
        publicKey: publicKey,
      );
      
      // Сохраняем сессию
      final authProvider = context.read<AuthProvider>();
      await authProvider.completeDeviceLinking(
        userId: result['user_id'],
        username: result['username'],
        deviceId: _deviceId!,
        token: result['token'] as String?,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Устройство привязано к ${result['username']}!'),
            backgroundColor: Colors.green,
          ),
        );
        
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isCompleting = false;
      });
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _submitCode() {
    final input = _codeController.text.trim().toUpperCase();
    if (input.isEmpty) return;
    
    // Проверяем формат: CODE:KEY или просто CODE
    if (input.contains(':')) {
      final parts = input.split(':');
      if (parts.length >= 2) {
        final code = parts[0];
        final key = parts.sublist(1).join(':'); // На случай если в ключе есть :
        _completeLink(code, importedKey: key);
        return;
      }
    }
    
    // Только код без ключа
    _completeLink(input);
  }

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[850],
        title: const Text('Привязать устройство', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isCompleting
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(
                    'Привязка устройства...',
                    style: TextStyle(color: Colors.grey[400], fontSize: 16),
                  ),
                ],
              ),
            )
          : _isScanning
              ? _buildScanner()
              : _buildMain(isDesktop),
    );
  }

  Widget _buildMain(bool isDesktop) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Основной способ — сканирование QR
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.green.withOpacity(0.3), width: 2),
            ),
            child: Column(
              children: [
                Icon(Icons.qr_code_scanner, size: 48, color: Colors.green[400]),
                const SizedBox(height: 16),
                const Text(
                  'Рекомендуемый способ',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Отсканируйте QR-код с основного устройства.\nКлюч шифрования передастся автоматически.',
                  style: TextStyle(color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (!isDesktop)
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: () => setState(() => _isScanning = true),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Сканировать QR'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[600],
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    '📷 Камера недоступна на десктопе.\nИспользуйте ввод кода ниже.',
                    style: TextStyle(color: Colors.orange[400]),
                    textAlign: TextAlign.center,
                  ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Разделитель
          Row(
            children: [
              Expanded(child: Divider(color: Colors.grey[700])),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('или', style: TextStyle(color: Colors.grey[500])),
              ),
              Expanded(child: Divider(color: Colors.grey[700])),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Ручной ввод
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(Icons.keyboard, size: 48, color: Colors.orange[400]),
                const SizedBox(height: 16),
                const Text(
                  'Ручной ввод',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Введите код (или код:ключ) с основного устройства',
                  style: TextStyle(color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                
                TextField(
                  controller: _codeController,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'XXXX-XXXX или код:ключ',
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 14),
                    filled: true,
                    fillColor: Colors.grey[800],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  maxLines: 3,
                  minLines: 1,
                  onSubmitted: (_) => _submitCode(),
                ),
                
                const SizedBox(height: 16),
                
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _submitCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange[600],
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Привязать',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
                
                const SizedBox(height: 12),
                Text(
                  '⚠️ Если ввели только код — ключ будет новый,\nстарые сообщения не расшифруются',
                  style: TextStyle(color: Colors.orange[400], fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final barcodes = capture.barcodes;
            if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
              _onCodeScanned(barcodes.first.rawValue!);
            }
          },
        ),
        Positioned(
          top: 100,
          left: 0,
          right: 0,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Сканируйте QR-код с основного устройства',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Center(
            child: ElevatedButton(
              onPressed: () => setState(() => _isScanning = false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Отмена', style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ],
    );
  }
}