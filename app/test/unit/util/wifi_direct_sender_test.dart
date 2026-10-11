import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/wifi_direct_sender.dart';

late StoredSecurityContext _security;

CrossFile _file(String name, List<int> bytes, {String? path}) => CrossFile(
      name: name,
      fileType: FileType.other,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: path,
      bytes: path == null ? bytes : null,
      lastModified: null,
      lastAccessed: null,
    );

Future<void> _reply(HttpRequest request, int status, [Object? body]) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  if (body != null) request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<HttpServer> _receiver(Future<void> Function(HttpRequest) handler, {bool tls = false}) async {
  final server = tls
      ? await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          SecurityContext()
            ..usePrivateKeyBytes(utf8.encode(_security.privateKey))
            ..useCertificateChainBytes(utf8.encode(_security.certificate)),
        )
      : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await handler(request);
    } on HttpException {
      // Expected when the sender aborts an in-flight upload.
    } on SocketException {
      // Expected when the sender cancels a pending offer.
    }
  });
  addTearDown(() async => server.close(force: true));
  return server;
}

Future<void> _info(HttpRequest request) => _reply(request, 200, {
      'alias': 'Test phone',
      'version': '2.2',
      'deviceType': 'mobile',
      'fingerprint': _security.certificateHash,
    });

// Required RegisterDtoV2 fields used by LocalSend v1.18.2's prepare-upload
// parser. In particular, serde rejects null for the required u16 port:
// https://github.com/localsend/localsend/blob/v1.18.2/packages/core/src/http/dto_v2.rs
bool _accepts1182SenderInfo(Object? value) {
  if (value is! Map<String, dynamic>) return false;
  final port = value['port'];
  return value['alias'] is String &&
      value['version'] is String &&
      value['fingerprint'] is String &&
      port is int &&
      port >= 0 &&
      port <= 65535 &&
      ['http', 'https'].contains(value['protocol']) &&
      (!value.containsKey('download') || value['download'] is bool);
}

WifiDirectSender _sender(HttpServer server, {bool tls = false, Future<String> Function(String)? source}) => WifiDirectSender(
      phoneIp: '127.0.0.1',
      port: server.port,
      https: tls,
      securityContext: _security,
      resolveSourceAddress: source ?? (_) async => '127.0.0.1',
      senderInfo: const InfoRegisterDto(
        alias: 'PC Wi-Fi Sender',
        version: '2.1',
        deviceModel: 'Windows',
        deviceType: DeviceType.desktop,
        fingerprint: 'sender-fingerprint',
        port: null,
        protocol: ProtocolType.https,
        download: false,
      ),
    );

void main() {
  setUpAll(() {
    _security = generateSecurityContext();
    MapperContainer.globals.use(const FileDtoMapper());
  });

  for (final tls in [false, true]) {
    test('Uploads disk, byte and empty files over ${tls ? 'HTTPS' : 'HTTP'} using receiver tokens', () async {
      final directory = await Directory.systemTemp.createTemp('localsend-sender-test');
      addTearDown(() async => directory.delete(recursive: true));
      final largeBytes = List.generate(200000, (index) => index % 256);
      final disk = File('${directory.path}/disk.bin');
      await disk.writeAsBytes(largeBytes);
      final expected = {
        'folder/файл & 空.bin': largeBytes,
        'bytes.bin': [0, 1, 255, 128],
        'empty.bin': <int>[]
      };
      final names = <String, String>{};
      final received = <String, List<int>>{};
      final routes = <String>[];
      final server = await _receiver((request) async {
        routes.add(request.uri.path);
        expect(request.connectionInfo!.remoteAddress.address, '127.0.0.1');
        switch (request.uri.path.split('/').last) {
          case 'info':
            await _info(request);
          case 'prepare-upload':
            expect(request.uri.queryParameters['pin'], '1234');
            final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
            if (!_accepts1182SenderInfo(body['info'])) {
              await _reply(request, 400, {'message': 'Invalid JSON body'});
              return;
            }
            expect(body['info']['port'], defaultPort);
            expect(body['info']['alias'], 'PC Wi-Fi Sender');
            expect(body['info']['download'], false);
            final files = body['files'] as Map<String, dynamic>;
            for (final entry in files.entries) {
              names[entry.key] = entry.value['fileName'] as String;
              expect(entry.value['size'], expected[names[entry.key]]!.length);
            }
            await _reply(request, 200, {
              'sessionId': 'session & 1',
              'files': {for (final id in files.keys) id: 'token & ?$id'}
            });
          case 'upload':
            final id = request.uri.queryParameters['fileId']!;
            expect(request.uri.queryParameters['sessionId'], 'session & 1');
            expect(request.uri.queryParameters['token'], 'token & ?$id');
            final bytes = await request.fold<List<int>>([], (value, chunk) => value..addAll(chunk));
            expect(request.headers.contentLength, expected[names[id]]!.length);
            received[names[id]!] = bytes;
            await _reply(request, 200);
          default:
            fail('Unexpected request ${request.uri}');
        }
      }, tls: tls);
      final progress = <int>[];
      final result = await _sender(server, tls: tls).send(
        files: [_file(expected.keys.first, largeBytes, path: disk.path), _file('bytes.bin', expected['bytes.bin']!), _file('empty.bin', [])],
        pin: '1234',
        onStatus: (_) {},
        onProgress: (sent, total) {
          expect(sent, lessThanOrEqualTo(total));
          progress.add(sent);
        },
      );
      expect(received, expected);
      expect(result.sentFiles, 3);
      expect(result.skippedFiles, 0);
      expect(result.receiverAlias, 'Test phone');
      expect(progress.last, 200004);
      expect(routes, ['/api/localsend/v2/info', '/api/localsend/v2/prepare-upload', ...List.filled(3, '/api/localsend/v2/upload')]);
    });
  }

  test('LocalSend 1.18.2 receiver rejects the previous null-port offer before acceptance', () async {
    bool accepted = false;
    final server = await _receiver((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      if (!_accepts1182SenderInfo(body['info'])) {
        await _reply(request, 400, {'message': 'Invalid JSON body'});
        return;
      }
      accepted = true;
      await _reply(request, 204);
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/api/localsend/v2/prepare-upload'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'info': _sender(server).senderInfo.toJson(), 'files': <String, Object>{}}));
    final response = await request.close();
    expect(response.statusCode, 400);
    expect(await utf8.decoder.bind(response).join(), contains('Invalid JSON body'));
    expect(accepted, false);
  });

  test('Reports the request stage when the receiver returns HTTP 400', () async {
    final server = await _receiver((request) async {
      if (request.uri.path.endsWith('/info')) {
        await _info(request);
      } else {
        await request.drain<void>();
        await _reply(request, 400, {'message': 'Invalid JSON body'});
      }
    });
    await expectLater(
      _sender(server).send(files: [
        _file('one', [1])
      ], onStatus: (_) {}, onProgress: (_, __) {}),
      throwsA(isA<WifiTransferException>().having((error) => error.message, 'message', contains('HTTP 400 during transfer offer (prepare-upload)'))),
    );
  });

  test('Uploads only selected files and reports skipped files', () async {
    int uploads = 0;
    final server = await _receiver((request) async {
      switch (request.uri.path.split('/').last) {
        case 'info':
          await _info(request);
        case 'prepare-upload':
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          final id = (body['files'] as Map).keys.first;
          await _reply(request, 200, {
            'sessionId': 's',
            'files': {id: 't'}
          });
        case 'upload':
          uploads++;
          await request.drain<void>();
          await _reply(request, 200);
      }
    });
    final result = await _sender(server).send(files: [
      _file('one', [1]),
      _file('two', [2])
    ], onStatus: (_) {}, onProgress: (_, __) {});
    expect(uploads, 1);
    expect(result.sentFiles, 1);
    expect(result.skippedFiles, 1);
  });

  for (final status in [401, 403, 409, 429]) {
    test('Handles receiver refusal HTTP $status without uploading', () async {
      int uploads = 0;
      final server = await _receiver((request) async {
        switch (request.uri.path.split('/').last) {
          case 'info':
            await _info(request);
          case 'prepare-upload':
            await request.drain<void>();
            await _reply(request, status);
          default:
            uploads++;
            await _reply(request, 500);
        }
      });
      await expectLater(
        _sender(server).send(files: [
          _file('one', [1])
        ], onStatus: (_) {}, onProgress: (_, __) {}),
        throwsA(isA<WifiTransferException>()),
      );
      expect(uploads, 0);
    });
  }

  test('Missing Wi-Fi prevents even the first network request', () async {
    int requests = 0;
    final server = await _receiver((request) async {
      requests++;
      await _info(request);
    });
    final sender = _sender(server, source: (_) async => throw StateError('No Wi-Fi'));
    await expectLater(
        sender.send(files: [
          _file('one', [1])
        ], onStatus: (_) {}, onProgress: (_, __) {}),
        throwsStateError);
    expect(requests, 0);
  });

  test('Wi-Fi address changes stop the transfer before an offer', () async {
    bool changed = false;
    int requests = 0;
    final server = await _receiver((request) async {
      requests++;
      changed = true;
      await _info(request);
    });
    final sender = _sender(server, source: (_) async => changed ? '127.0.0.2' : '127.0.0.1');
    await expectLater(
        sender.send(files: [
          _file('one', [1])
        ], onStatus: (_) {}, onProgress: (_, __) {}),
        throwsA(isA<WifiTransferException>()));
    expect(requests, 1);
  });

  test('Cancel interrupts a pending offer and notifies the receiver', () async {
    final offered = Completer<void>();
    final canceled = Completer<void>();
    final server = await _receiver((request) async {
      switch (request.uri.path.split('/').last) {
        case 'info':
          await _info(request);
        case 'prepare-upload':
          await request.drain<void>();
          offered.complete();
          await canceled.future;
          await _reply(request, 403);
        case 'cancel':
          expect(request.uri.queryParameters, isEmpty);
          canceled.complete();
          await _reply(request, 200);
        default:
          fail('No upload should start after cancellation');
      }
    });
    final sender = _sender(server);
    final transfer = sender.send(files: [
      _file('one', [1])
    ], onStatus: (_) {}, onProgress: (_, __) {});
    final assertion = expectLater(transfer, throwsA(isA<WifiTransferCancelled>()));
    await offered.future;
    sender.cancel();
    await assertion;
    expect(canceled.isCompleted, true);
  });

  test('Upload errors cancel the session and do not claim success', () async {
    bool canceled = false;
    final server = await _receiver((request) async {
      switch (request.uri.path.split('/').last) {
        case 'info':
          await _info(request);
        case 'prepare-upload':
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          await _reply(request, 200, {
            'sessionId': 'failed-session',
            'files': {for (final id in (body['files'] as Map).keys) id: 't'}
          });
        case 'upload':
          await request.drain<void>();
          await _reply(request, 500);
        case 'cancel':
          expect(request.uri.queryParameters['sessionId'], 'failed-session');
          canceled = true;
          await _reply(request, 200);
      }
    });
    await expectLater(
      _sender(server).send(files: [
        _file('one', [1])
      ], onStatus: (_) {}, onProgress: (_, __) {}),
      throwsA(isA<WifiTransferException>()),
    );
    expect(canceled, true);
  });

  test('Redirects never contact another receiver', () async {
    int requests = 0;
    final server = await _receiver((request) async {
      requests++;
      request.response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:9/redirect');
      await _reply(request, 302);
    });
    await expectLater(
      _sender(server).send(files: [
        _file('one', [1])
      ], onStatus: (_) {}, onProgress: (_, __) {}),
      throwsA(isA<WifiTransferException>()),
    );
    expect(requests, 1);
  });
}
