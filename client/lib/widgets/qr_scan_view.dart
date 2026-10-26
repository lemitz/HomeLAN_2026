// lib/widgets/qr_scan_view.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/biometric_service.dart';

/// Камера доступна только на мобильных платформах.
bool get canScanQr => Platform.isAndroid || Platform.isIOS;

/// Полноэкранный сканер QR. Возвращает первую строку, принятую [accept].
class QrScanPage extends StatefulWidget {
  final String hint;
  final bool Function(String value) accept;

  const QrScanPage({super.key, required this.hint, required this.accept});

  /// Открывает сканер и возвращает результат (или null при отмене).
  static Future<String?> open(BuildContext context, {required String hint, required bool Function(String) accept}) {
    return BiometricService().withoutLock(() => Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (_) => QrScanPage(hint: hint, accept: accept)),
        ));
  }

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;
  DateTime? _lastReject;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v == null) continue;
      if (widget.accept(v)) {
        _done = true;
        Navigator.pop(context, v);
        return;
      }
    }
    final now = DateTime.now();
    if (_lastReject == null || now.difference(_lastReject!).inSeconds >= 3) {
      _lastReject = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Это не тот QR-код'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканирование')),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Positioned(
            top: 24,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration:
                  BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12)),
              child: Text(widget.hint,
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
