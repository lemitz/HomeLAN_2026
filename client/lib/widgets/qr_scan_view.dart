// lib/widgets/qr_scan_view.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/strings.dart';
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
        SnackBar(content: Text(S.of(context).wrongQr), duration: const Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text(widget.hint, style: const TextStyle(fontSize: 16))),
      body: Stack(children: [
        MobileScanner(onDetect: _onDetect),
        // Рамка прицела.
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
      ]),
    );
  }
}
