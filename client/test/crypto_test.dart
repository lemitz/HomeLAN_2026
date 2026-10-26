import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homelan_client/services/crypto_service.dart';
import 'package:homelan_client/services/file_cipher.dart';
import 'package:homelan_client/services/linking_service.dart';

const aliceId = 1;
const bobId = 2;

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CryptoService alice;
  late CryptoService bob;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    alice = CryptoService();
    bob = CryptoService();
    final alicePub = await alice.generateIdentity();
    final bobPub = await bob.generateIdentity();
    expect(await alice.registerPeerKey(bobId, bobPub), PeerKeyStatus.trusted);
    expect(await bob.registerPeerKey(aliceId, alicePub), PeerKeyStatus.trusted);
  });

  Future<Uint8List> aliceSends(String text, {String type = 'text', String clientId = 'c1'}) =>
      alice.encryptMessage(plaintext: bytes(text), myId: aliceId, peerId: bobId, contentType: type, clientId: clientId);

  Future<String> bobReads(Uint8List blob,
          {int sender = aliceId, int recipient = bobId, String type = 'text', String clientId = 'c1'}) async =>
      utf8.decode(await bob.decryptMessage(
          blob: blob,
          myId: bobId,
          peerId: aliceId,
          senderId: sender,
          recipientId: recipient,
          contentType: type,
          clientId: clientId));

  test('roundtrip and format', () async {
    final blob = await aliceSends('Привет');
    expect(blob[0], kCryptoVersion);
    expect(blob.length, 1 + 24 + utf8.encode('Привет').length + 16);
    expect(await bobReads(blob), 'Привет');

    // Отправитель может прочитать своё сообщение (на другом своём устройстве).
    final own = await alice.decryptMessage(
        blob: blob,
        myId: aliceId,
        peerId: bobId,
        senderId: aliceId,
        recipientId: bobId,
        contentType: 'text',
        clientId: 'c1');
    expect(utf8.decode(own), 'Привет');
  });

  test('nonces are random', () async {
    final a = await aliceSends('same');
    final b = await aliceSends('same');
    expect(a, isNot(equals(b)));
  });

  test('metadata is authenticated: type, client id, direction', () async {
    final blob = await aliceSends('secret');
    await expectLater(() => bobReads(blob, type: 'file'), throwsA(isA<CryptoException>()));
    await expectLater(() => bobReads(blob, clientId: 'other'), throwsA(isA<CryptoException>()));
    // Отражение: сервер выдаёт сообщение Алисы за сообщение Боба.
    await expectLater(() => bobReads(blob, sender: bobId, recipient: aliceId), throwsA(isA<CryptoException>()));
    // Порча шифротекста.
    final broken = Uint8List.fromList(blob)..[30] ^= 1;
    await expectLater(() => bobReads(broken), throwsA(isA<CryptoException>()));
    // Не v2 / открытый текст.
    await expectLater(
        () => bobReads(bytes('plain text message here, not encrypted!')), throwsA(isA<CryptoException>()));
  });

  test('TOFU blocks a substituted peer key until accepted', () async {
    final evil = await EphemeralKey.generate();
    expect(await alice.registerPeerKey(bobId, evil.publicKey), PeerKeyStatus.mismatch);
    expect(alice.peerStatus(bobId), PeerKeyStatus.mismatch);
    await expectLater(() => aliceSends('x'), throwsA(isA<CryptoException>()));

    await alice.acceptPendingPeerKey(bobId);
    expect(alice.peerStatus(bobId), PeerKeyStatus.trusted);
    expect(CryptoService.equalBytes(alice.peerKey(bobId)!, evil.publicKey), isTrue);
  });

  test('safety number is symmetric and changes with keys', () async {
    final a = await alice.identityPublicKey();
    final b = await bob.identityPublicKey();
    final n1 = await CryptoService.safetyNumber(a, b);
    final n2 = await CryptoService.safetyNumber(b, a);
    expect(n1, n2);
    expect(n1.split(' ').length, 12);
    expect(RegExp(r'^(\d{5} ){11}\d{5}$').hasMatch(n1), isTrue);
    final other = await EphemeralKey.generate();
    expect(await CryptoService.safetyNumber(a, other.publicKey), isNot(n1));
  });

  test('identity import verifies expected public key', () async {
    final priv = await alice.exportIdentityPrivate();
    final pub = await alice.identityPublicKey();
    final c = CryptoService();
    await c.importIdentity(priv, expectedPublic: pub);
    expect(CryptoService.equalBytes(await c.identityPublicKey(), pub), isTrue);
    final wrong = await EphemeralKey.generate();
    await expectLater(() => c.importIdentity(priv, expectedPublic: wrong.publicKey), throwsA(isA<CryptoException>()));
  });

  group('linking', () {
    test('identity transfer works only for the intended device', () async {
      final identity = await alice.exportIdentityPrivate();
      final newDevice = await EphemeralKey.generate();
      final req = LinkRequest(
          deviceId: 'dev-new-1234567890',
          deviceName: 'PC',
          deviceType: 'windows',
          ephemeralPublic: newDevice.publicKey);
      final parsedReq = LinkRequest.tryParse(req.encode())!;
      expect(parsedReq.deviceId, req.deviceId);

      final (ephPub, ct) = await LinkCrypto.seal(
          identityPrivate: identity,
          newDevicePublic: parsedReq.ephemeralPublic,
          deviceId: parsedReq.deviceId,
          code: 'ABCDE-FGHJK');
      final resp =
          LinkResponse.tryParse(LinkResponse(code: 'ABCDE-FGHJK', ephemeralPublic: ephPub, ciphertext: ct).encode())!;

      final opened = await LinkCrypto.open(
          ephemeralPrivate: newDevice.privateKey,
          oldDevicePublic: resp.ephemeralPublic,
          ciphertext: resp.ciphertext,
          deviceId: req.deviceId,
          code: resp.code);
      expect(opened, identity);

      final attacker = await EphemeralKey.generate();
      await expectLater(
          () => LinkCrypto.open(
              ephemeralPrivate: attacker.privateKey,
              oldDevicePublic: resp.ephemeralPublic,
              ciphertext: resp.ciphertext,
              deviceId: req.deviceId,
              code: resp.code),
          throwsA(isA<CryptoException>()));
      await expectLater(
          () => LinkCrypto.open(
              ephemeralPrivate: newDevice.privateKey,
              oldDevicePublic: resp.ephemeralPublic,
              ciphertext: resp.ciphertext,
              deviceId: 'other-device-000000',
              code: resp.code),
          throwsA(isA<CryptoException>()));
    });

    test('text format tolerates whitespace and rejects garbage', () async {
      final k = await EphemeralKey.generate();
      final text = LinkRequest(deviceId: 'd' * 22, deviceName: 'n', deviceType: 'android', ephemeralPublic: k.publicKey)
          .encode();
      final wrapped = '${text.substring(0, 20)}\n  ${text.substring(20)} ';
      expect(LinkRequest.tryParse(wrapped), isNotNull);
      expect(LinkRequest.tryParse('HL1:garbage'), isNull);
      expect(LinkResponse.tryParse(text), isNull);
    });

    test('verification code is stable', () async {
      final k = await EphemeralKey.generate();
      final c = await LinkCrypto.verificationCode(k.publicKey);
      expect(c, await LinkCrypto.verificationCode(k.publicKey));
      expect(RegExp(r'^\d{3} \d{3}$').hasMatch(c), isTrue);
    });
  });

  group('file cipher', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('hlf'));
    tearDown(() async => dir.delete(recursive: true));

    Future<void> roundtrip(int size) async {
      final data = Uint8List.fromList(List.generate(size, (i) => Random(size).nextInt(256)));
      final src = File('${dir.path}/src_$size')..writeAsBytesSync(data);
      final enc = '${dir.path}/enc_$size';
      final out = '${dir.path}/out_$size';
      final key = FileCipher.newKey();
      await FileCipher.encrypt(src.path, enc, key);
      expect(File(enc).lengthSync(), FileCipher.encryptedSize(size));
      await FileCipher.decrypt(enc, out, key);
      expect(File(out).readAsBytesSync(), data);
    }

    test('empty, small, exact-chunk and multi-chunk files', () async {
      await roundtrip(0);
      await roundtrip(1000);
      await roundtrip(FileCipher.chunkSize);
      await roundtrip(FileCipher.chunkSize * 2 + 123);
    });

    test('tampering, truncation and wrong key are detected', () async {
      final src = File('${dir.path}/s')..writeAsBytesSync(List.filled(FileCipher.chunkSize + 10, 7));
      final enc = '${dir.path}/e';
      final key = FileCipher.newKey();
      await FileCipher.encrypt(src.path, enc, key);
      final good = File(enc).readAsBytesSync();

      Future<void> expectFail(List<int> content, Uint8List k) async {
        final f = File('${dir.path}/bad')..writeAsBytesSync(content);
        final out = '${dir.path}/bad_out';
        await expectLater(FileCipher.decrypt(f.path, out, k), throwsA(anything));
        expect(File(out).existsSync(), isFalse, reason: 'partial plaintext must be removed');
      }

      await expectFail(Uint8List.fromList(good)..[100] ^= 1, key);
      await expectFail(good.sublist(0, 24 + FileCipher.chunkSize + 16), key); // отрезан последний блок
      await expectFail(good, FileCipher.newKey());
    });
  });
}
