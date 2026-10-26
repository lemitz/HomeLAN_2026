// Сквозной тест клиентского кода против НАСТОЯЩЕГО сервера.
//
// Запуск (сервер должен быть свежим, с пустой БД):
//   homelan-server --key-file ./homelan.key --config ./config.yaml
//   HOMELAN_E2E_URL=http://127.0.0.1:18080 flutter test test/e2e_server_test.dart
@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homelan_client/models/models.dart';
import 'package:homelan_client/services/services.dart';

final url = Platform.environment['HOMELAN_E2E_URL'];

class Client {
  final api = ApiService(baseUrl: url!);
  final ws = WebSocketService(baseUrl: url!);
  final crypto = CryptoService();
  late UserInfo user;
  late String deviceId;
  final inbox = <Map<String, dynamic>>[];
  StreamSubscription? sub;

  void listen() => sub = ws.messages.listen(inbox.add);

  Future<Map<String, dynamic>> waitFor(String type, {bool Function(Map<String, dynamic>)? where}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      for (final m in List.of(inbox)) {
        if (m['type'] == type && (where == null || where(m['data'] as Map<String, dynamic>))) {
          inbox.remove(m);
          return m['data'] as Map<String, dynamic>;
        }
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('no $type; inbox=${inbox.map((m) => m['type']).toList()}');
  }

  Future<void> connect() async {
    final connected = Completer<void>();
    ws.onConnected = () {
      if (!connected.isCompleted) connected.complete();
    };
    listen();
    ws.start(api.token!);
    await connected.future.timeout(const Duration(seconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Тестовая привязка подменяет HTTP заглушкой — здесь нужна настоящая сеть.
  HttpOverrides.global = null;

  test('full protocol flow against a real server', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final suffix = DateTime.now().millisecondsSinceEpoch % 100000;

    // --- регистрация двух пользователей ---
    Future<Client> register(String name) async {
      final c = Client();
      final identity = await EphemeralKey.generate();
      c.deviceId = DeviceInfo.newDeviceId();
      final data = await c.api.register(
        username: '$name$suffix',
        password: 'password-$name',
        deviceId: c.deviceId,
        deviceName: '$name-test',
        deviceType: 'windows',
        publicKey: identity.publicKey,
      );
      await c.crypto.importIdentity(identity.privateKey, expectedPublic: identity.publicKey);
      c.api.token = data['token'] as String;
      c.user = UserInfo.fromJson(data['user'])!;
      expect(CryptoService.equalBytes(c.user.publicKey, identity.publicKey), isTrue);
      return c;
    }

    final alice = await register('alice');
    final bob = await register('bob');

    // Ошибки сервера разбираются в ApiException с кодом.
    await expectLater(
      alice.api.login(username: 'alice$suffix', password: 'wrong-password', deviceId: alice.deviceId),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials')),
    );
    await expectLater(
      alice.api.login(username: 'alice$suffix', password: 'password-alice', deviceId: DeviceInfo.newDeviceId()),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'device_not_linked')),
    );

    // Ключи собеседников (TOFU).
    final partnerOfAlice = UserInfo.fromJson(await alice.api.partner())!;
    expect(partnerOfAlice.id, bob.user.id);
    await alice.crypto.registerPeerKey(bob.user.id, partnerOfAlice.publicKey);
    await bob.crypto.registerPeerKey(alice.user.id, alice.user.publicKey);

    await alice.connect();
    await bob.connect();

    // --- текстовое сообщение ---
    const clientId = 'e2e-msg-1';
    final blob = await alice.crypto.encryptMessage(
        plaintext: Uint8List.fromList(utf8.encode('Привет, Боб!')),
        myId: alice.user.id,
        peerId: bob.user.id,
        contentType: 'text',
        clientId: clientId);
    alice.ws.send('send_message', {
      'client_id': clientId,
      'recipient_id': bob.user.id,
      'content_type': 'text',
      'encrypted_content': base64Encode(blob),
    });
    final sent = await alice.waitFor('message_sent');
    expect(sent['client_id'], clientId);

    final got = Message.fromServer(await bob.waitFor('message', where: (d) => d['client_id'] == clientId));
    final clear = await bob.crypto.decryptMessage(
        blob: got.encryptedContent,
        myId: bob.user.id,
        peerId: alice.user.id,
        senderId: got.senderId,
        recipientId: got.recipientId,
        contentType: got.contentType,
        clientId: got.clientId);
    expect(utf8.decode(clear), 'Привет, Боб!');

    // Статусы доходят до отправителя.
    bob.ws.send('ack', {'seq_id': got.seqId});
    await alice.waitFor('message', where: (d) => d['seq_id'] == got.seqId && d['delivered_at'] != null);
    bob.ws.send('read', {'up_to_seq': got.seqId});
    await alice.waitFor('message', where: (d) => d['seq_id'] == got.seqId && d['read_at'] != null);

    // Синк по курсору возвращает финальное состояние.
    bob.ws.send('sync', {'since': 0});
    final sync = await bob.waitFor('sync_response');
    final synced = Message.fromServer((sync['messages'] as List).last as Map<String, dynamic>);
    expect(synced.deliveryStatus, DeliveryStatus.read);

    // --- файл ---
    final tmp = await Directory.systemTemp.createTemp('hl_e2e');
    final src = File('${tmp.path}/photo.jpg')..writeAsBytesSync(List.generate(300000, (i) => i % 251));
    final key = FileCipher.newKey();
    await FileCipher.encrypt(src.path, '${tmp.path}/enc', key);
    double lastProgress = 0;
    final fileId = await alice.api.uploadFile('${tmp.path}/enc', onProgress: (p) => lastProgress = p);
    expect(lastProgress, closeTo(1.0, 0.0001));

    final meta = FileMeta(name: 'photo.jpg', size: 300000, mime: 'image/jpeg', key: key);
    const fileClientId = 'e2e-file-1';
    final metaBlob = await alice.crypto.encryptMessage(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson()))),
        myId: alice.user.id,
        peerId: bob.user.id,
        contentType: 'image',
        clientId: fileClientId);
    alice.ws.send('send_message', {
      'client_id': fileClientId,
      'recipient_id': bob.user.id,
      'content_type': 'image',
      'file_id': fileId,
      'encrypted_content': base64Encode(metaBlob),
    });
    final fileMsg = Message.fromServer(await bob.waitFor('message', where: (d) => d['client_id'] == fileClientId));
    final metaClear = await bob.crypto.decryptMessage(
        blob: fileMsg.encryptedContent,
        myId: bob.user.id,
        peerId: alice.user.id,
        senderId: fileMsg.senderId,
        recipientId: fileMsg.recipientId,
        contentType: fileMsg.contentType,
        clientId: fileMsg.clientId);
    final gotMeta = FileMeta.fromJson(jsonDecode(utf8.decode(metaClear)));
    await bob.api.downloadFile(fileMsg.fileId!, '${tmp.path}/dl');
    await FileCipher.decrypt('${tmp.path}/dl', '${tmp.path}/out.jpg', gotMeta.key);
    expect(File('${tmp.path}/out.jpg').readAsBytesSync(), src.readAsBytesSync());

    // --- привязка нового устройства Алисы (2-QR) ---
    final newDevice = await EphemeralKey.generate();
    final req = LinkRequest(
        deviceId: DeviceInfo.newDeviceId(), deviceName: 'Alice PC', deviceType: 'windows', ephemeralPublic: newDevice.publicKey);
    final parsed = LinkRequest.tryParse(req.encode())!;
    final linkData = await alice.api
        .createLinkCode(deviceId: parsed.deviceId, deviceName: parsed.deviceName, deviceType: parsed.deviceType);
    final code = linkData['link_code'] as String;
    final (ephPub, ct) = await LinkCrypto.seal(
        identityPrivate: await alice.crypto.exportIdentityPrivate(),
        newDevicePublic: parsed.ephemeralPublic,
        deviceId: parsed.deviceId,
        code: code);
    final resp = LinkResponse.tryParse(LinkResponse(code: code, ephemeralPublic: ephPub, ciphertext: ct).encode())!;

    final pc = Client()..deviceId = req.deviceId;
    final identity = await LinkCrypto.open(
        ephemeralPrivate: newDevice.privateKey,
        oldDevicePublic: resp.ephemeralPublic,
        ciphertext: resp.ciphertext,
        deviceId: req.deviceId,
        code: resp.code);
    final completed = await pc.api.completeLinking(linkCode: resp.code, deviceId: req.deviceId);
    pc.user = UserInfo.fromJson(completed['user'])!;
    await pc.crypto.importIdentity(identity, expectedPublic: pc.user.publicKey);
    pc.api.token = completed['token'] as String;
    await pc.crypto.registerPeerKey(bob.user.id, partnerOfAlice.publicKey);

    // Новое устройство досинхронизирует историю и читает старое сообщение.
    await pc.connect();
    pc.ws.send('sync', {'since': 0});
    final pcSync = await pc.waitFor('sync_response');
    final first = Message.fromServer((pcSync['messages'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => m['client_id'] == clientId));
    final pcClear = await pc.crypto.decryptMessage(
        blob: first.encryptedContent,
        myId: pc.user.id,
        peerId: bob.user.id,
        senderId: first.senderId,
        recipientId: first.recipientId,
        contentType: first.contentType,
        clientId: first.clientId);
    expect(utf8.decode(pcClear), 'Привет, Боб!');

    // --- отзыв устройства: и HTTP, и WS сразу теряют доступ ---
    final unauthorized = Completer<void>();
    pc.ws.onUnauthorized = () => unauthorized.complete();
    await alice.api.revokeDevice(pc.deviceId);
    await expectLater(pc.api.session(), throwsA(isA<ApiException>().having((e) => e.isUnauthorized, '401', true)));
    await unauthorized.future.timeout(const Duration(seconds: 10));

    // --- удаление: tombstone приходит собеседнику ---
    alice.ws.send('delete', {'seq_id': got.seqId});
    await bob.waitFor('message', where: (d) => d['seq_id'] == got.seqId && d['is_deleted'] == true);

    alice.ws.stop();
    bob.ws.stop();
    pc.ws.stop();
    await tmp.delete(recursive: true);
  }, skip: url == null ? 'set HOMELAN_E2E_URL to run' : false, timeout: const Timeout(Duration(minutes: 2)));
}
