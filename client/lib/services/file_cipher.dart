// lib/services/file_cipher.dart
//
// Потоковое шифрование файлов (до нескольких ГБ без загрузки в память).
//
// Каждый файл шифруется своим случайным 32-байтовым ключом; ключ передаётся
// собеседнику внутри зашифрованного сообщения с метаданными.
//
// Формат: заголовок "HLF2" | u32 размер блока | 16 байт префикса nonce,
// затем блоки XChaCha20-Poly1305. Nonce блока = префикс | u64 номер блока.
// AAD = заголовок | u64 номер | флаг последнего блока — блоки нельзя
// переставить, обрезать или дописать.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

class FileCipher {
  static const _magic = [0x48, 0x4C, 0x46, 0x32]; // HLF2
  static const chunkSize = 256 * 1024;
  static const _headerSize = 4 + 4 + 16;
  static const _macSize = 16;

  static Uint8List newKey() => Uint8List.fromList(SecretKeyData.random(length: 32).bytes);

  /// Размер зашифрованного файла по размеру исходного.
  static int encryptedSize(int plainSize) {
    final chunks = plainSize == 0 ? 1 : (plainSize + chunkSize - 1) ~/ chunkSize;
    return _headerSize + plainSize + chunks * _macSize;
  }

  /// Шифрует файл в отдельном изоляте.
  static Future<void> encrypt(String inPath, String outPath, Uint8List key) =>
      Isolate.run(() => _encrypt(inPath, outPath, key));

  /// Расшифровывает файл в отдельном изоляте. При ошибке выходной файл удаляется.
  static Future<void> decrypt(String inPath, String outPath, Uint8List key) =>
      Isolate.run(() => _decrypt(inPath, outPath, key));

  static Uint8List _nonce(Uint8List prefix, int index) {
    final n = Uint8List(24)..setRange(0, 16, prefix);
    ByteData.view(n.buffer).setUint64(16, index);
    return n;
  }

  static Uint8List _aad(Uint8List header, int index, bool last) {
    final a = Uint8List(header.length + 9)..setRange(0, header.length, header);
    ByteData.view(a.buffer).setUint64(header.length, index);
    a[a.length - 1] = last ? 1 : 0;
    return a;
  }

  static Future<void> _encrypt(String inPath, String outPath, Uint8List key) async {
    const aead = DartXchacha20.poly1305Aead();
    final secret = SecretKey(key);
    final prefix = Uint8List.fromList(SecretKeyData.random(length: 16).bytes);
    final header = Uint8List(_headerSize)
      ..setRange(0, 4, _magic)
      ..setRange(8, 24, prefix);
    ByteData.view(header.buffer).setUint32(4, chunkSize);

    final input = await File(inPath).open();
    final output = await File(outPath).open(mode: FileMode.write);
    try {
      await output.writeFrom(header);
      final total = await input.length();
      var offset = 0;
      var index = 0;
      do {
        final len = (total - offset) < chunkSize ? total - offset : chunkSize;
        final chunk = await input.read(len);
        offset += len;
        final last = offset >= total;
        final box =
            await aead.encrypt(chunk, secretKey: secret, nonce: _nonce(prefix, index), aad: _aad(header, index, last));
        await output.writeFrom(box.cipherText);
        await output.writeFrom(box.mac.bytes);
        index++;
      } while (offset < total);
      await output.flush();
    } finally {
      await input.close();
      await output.close();
    }
  }

  static Future<void> _decrypt(String inPath, String outPath, Uint8List key) async {
    const aead = DartXchacha20.poly1305Aead();
    final secret = SecretKey(key);
    final input = await File(inPath).open();
    final outFile = File(outPath);
    final output = await outFile.open(mode: FileMode.write);
    var ok = false;
    try {
      final total = await input.length();
      final header = await input.read(_headerSize);
      if (header.length != _headerSize ||
          header[0] != _magic[0] ||
          header[1] != _magic[1] ||
          header[2] != _magic[2] ||
          header[3] != _magic[3]) {
        throw const FormatException('bad file header');
      }
      final size = ByteData.view(header.buffer).getUint32(4);
      if (size == 0 || size > 16 * 1024 * 1024) throw const FormatException('bad chunk size');
      final prefix = header.sublist(8, 24);

      var offset = _headerSize;
      var index = 0;
      var sawLast = false;
      while (offset < total) {
        final remaining = total - offset;
        final len = remaining < size + _macSize ? remaining : size + _macSize;
        if (len < _macSize) throw const FormatException('truncated file');
        final block = await input.read(len);
        offset += len;
        final last = offset >= total;
        final box = SecretBox(block.sublist(0, len - _macSize),
            nonce: _nonce(prefix, index), mac: Mac(block.sublist(len - _macSize)));
        final clear = await aead.decrypt(box, secretKey: secret, aad: _aad(header, index, last));
        await output.writeFrom(clear);
        sawLast = last;
        index++;
      }
      if (!sawLast) throw const FormatException('truncated file');
      await output.flush();
      ok = true;
    } finally {
      await input.close();
      await output.close();
      if (!ok && await outFile.exists()) await outFile.delete();
    }
  }
}
