import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/prepare_upload_response_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/util/native/wifi_address.dart';
import 'package:uuid/uuid.dart';

class WifiTransferException implements Exception {
  final String message;
  const WifiTransferException(this.message);
  @override
  String toString() => message;
}

class WifiTransferCancelled extends WifiTransferException {
  const WifiTransferCancelled() : super('Transfer canceled.');
}

class WifiTransferResult {
  final String receiverAlias;
  final int sentFiles;
  final int skippedFiles;
  const WifiTransferResult(this.receiverAlias, this.sentFiles, this.skippedFiles);
}

/// A single transfer using outgoing, source-bound TCP connections only.
/// No multicast, registration, listener, hostname lookup, proxy, or route changes.
class WifiDirectSender {
  final String phoneIp;
  final int port;
  final bool https;
  final InfoRegisterDto senderInfo;
  final StoredSecurityContext securityContext;
  final Future<String> Function(String peer) resolveSourceAddress;
  final Duration responseTimeout;

  HttpClient? _client;
  String? _sourceAddress;
  String? _sessionId;
  String? _peerCertificate;
  bool _offerPending = false;
  bool _started = false;
  final _cancellation = Completer<void>();
  final _connecting = <ConnectionTask<Socket>>{};

  WifiDirectSender({
    required this.phoneIp,
    required this.port,
    required this.https,
    required this.senderInfo,
    required this.securityContext,
    this.resolveSourceAddress = resolveWifiAddressForPeer,
    this.responseTimeout = const Duration(minutes: 3),
  });

  void cancel() {
    if (!_cancellation.isCompleted) _cancellation.complete();
    for (final task in _connecting) {
      task.cancel();
    }
    _client?.close(force: true);
  }

  Future<T> _guard<T>(Future<T> operation) => Future.any([
        operation,
        _cancellation.future.then<T>((_) => throw const WifiTransferCancelled()),
      ]);

  void _checkCanceled() {
    if (_cancellation.isCompleted) throw const WifiTransferCancelled();
  }

  Future<void> _ensureWifi() async {
    final current = await resolveSourceAddress(phoneIp);
    if (_sourceAddress != null && current != _sourceAddress) {
      throw const WifiTransferException('The Wi-Fi connection changed. Check the iPhone address and start a new transfer.');
    }
    _sourceAddress = current;
  }

  HttpClient _createClient() {
    final context = SecurityContext(withTrustedRoots: false)
      ..usePrivateKeyBytes(utf8.encode(securityContext.privateKey))
      ..useCertificateChainBytes(utf8.encode(securityContext.certificate));
    return HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        if (uri.host != phoneIp || uri.port != port || proxyHost != null) {
          throw const WifiTransferException('Refusing a connection outside the selected receiver.');
        }
        await _ensureWifi();
        final rawTask = await Socket.startConnect(InternetAddress(phoneIp), port, sourceAddress: InternetAddress(_sourceAddress!));
        Socket? connectedSocket;
        bool canceled = false;
        final socketFuture = rawTask.socket.then<Socket>((socket) async {
          connectedSocket = socket;
          if (canceled) {
            socket.destroy();
            throw const WifiTransferCancelled();
          }
          if (!https) return socket;
          // A custom HttpClient connectionFactory must perform TLS itself.
          // Upgrade the already Wi-Fi-bound socket, never connect a second one.
          final secure = await SecureSocket.secure(socket, host: phoneIp, context: context, onBadCertificate: (certificate) {
            final encoded = base64Encode(certificate.der);
            _peerCertificate ??= encoded;
            return _peerCertificate == encoded;
          });
          connectedSocket = secure;
          if (canceled) {
            secure.destroy();
            throw const WifiTransferCancelled();
          }
          return secure;
        });
        final task = ConnectionTask.fromSocket(socketFuture, () {
          canceled = true;
          rawTask.cancel();
          connectedSocket?.destroy();
        });
        _connecting.add(task);
        unawaited(task.socket.then<void>((_) => _connecting.remove(task), onError: (Object _) => _connecting.remove(task)));
        return task;
      };
  }

  Uri _uri(String route, [Map<String, String>? query]) => Uri(
        scheme: https ? 'https' : 'http',
        host: phoneIp,
        port: port,
        path: '/api/localsend/v2/$route',
        queryParameters: query,
      );

  Future<HttpClientRequest> _request(String method, Uri uri) async {
    _checkCanceled();
    await _guard(_ensureWifi());
    final request = await _guard(_client!.openUrl(method, uri));
    // Tokens and PINs must never follow a redirect to another address.
    request.followRedirects = false;
    return request;
  }

  Future<(int, String)> _response(HttpClientRequest request) async {
    final response = await _guard(request.close().timeout(responseTimeout));
    final builder = BytesBuilder();
    await _guard(response.timeout(responseTimeout).forEach((chunk) {
      if (builder.length + chunk.length > 1024 * 1024) {
        throw const WifiTransferException('The receiver returned an oversized response.');
      }
      builder.add(chunk);
    }));
    return (response.statusCode, utf8.decode(builder.takeBytes()));
  }

  void _requireSuccess(int status) {
    if (status >= 200 && status < 300) return;
    final message = switch (status) {
      401 => 'The iPhone requires a PIN, or the PIN is incorrect. Enter its receive PIN and retry.',
      403 => 'The iPhone declined the transfer or canceled receiving.',
      409 => 'The iPhone is busy. Close its previous transfer and retry.',
      429 => 'Too many PIN attempts. Wait before trying again.',
      _ => 'The iPhone returned HTTP $status. Check LocalSend on the iPhone.',
    };
    throw WifiTransferException(message);
  }

  Future<WifiTransferResult> send({
    required List<CrossFile> files,
    String? pin,
    required void Function(String message) onStatus,
    required void Function(int sent, int total) onProgress,
  }) async {
    if (_started) throw StateError('Create a new sender for each transfer.');
    _started = true;
    try {
      _checkCanceled();
      final address = InternetAddress.tryParse(phoneIp);
      if (address == null || address.type != InternetAddressType.IPv4 || port < 1 || port > 65535) {
        throw const WifiTransferException('Enter the iPhone Wi-Fi IPv4 address and a port from 1 to 65535.');
      }
      if (files.isEmpty) throw const WifiTransferException('Select at least one file.');
      for (final file in files) {
        if (file.path != null) {
          if (await File(file.path!).length() != file.size) {
            throw WifiTransferException('${file.name} changed after selection. Select it again.');
          }
        } else if (file.bytes == null || file.bytes!.length != file.size) {
          throw WifiTransferException('${file.name} is no longer available. Select it again.');
        }
      }
      await _guard(_ensureWifi());
      _client = _createClient();
      onStatus('Connecting to the iPhone…');
      final infoRequest = await _request('GET', _uri('info'));
      final (infoStatus, infoBody) = await _response(infoRequest);
      _requireSuccess(infoStatus);
      final info = InfoDto.fromJson(jsonDecode(infoBody));
      if (info.version == null || !info.version!.startsWith('2.')) {
        throw const WifiTransferException('Update LocalSend on the iPhone. This sender requires protocol v2.');
      }
      final selected = {for (final file in files) const Uuid().v4(): file};
      final metadata = {
        for (final entry in selected.entries)
          entry.key: FileDto(
            id: entry.key,
            fileName: entry.value.name,
            size: entry.value.size,
            fileType: entry.value.fileType,
            hash: null,
            preview: files.length == 1 && entry.value.fileType == FileType.text && entry.value.bytes != null ? utf8.decode(entry.value.bytes!) : null,
            legacy: false,
            metadata: FileMetadata(lastModified: entry.value.lastModified, lastAccessed: entry.value.lastAccessed),
          ),
      };
      onStatus('Waiting for ${info.alias}: tap Accept in LocalSend on the iPhone.');
      final offer = await _request('POST', _uri('prepare-upload', {if (pin != null && pin.isNotEmpty) 'pin': pin}));
      offer.headers.contentType = ContentType.json;
      offer.write(jsonEncode(PrepareUploadRequestDto(info: senderInfo, files: metadata).toJson()));
      _offerPending = true;
      final (offerStatus, offerBody) = await _response(offer);
      _offerPending = false;
      _requireSuccess(offerStatus);
      if (offerStatus == 204) return WifiTransferResult(info.alias, 0, files.length);
      final accepted = PrepareUploadResponseDto.fromJson(jsonDecode(offerBody));
      _sessionId = accepted.sessionId;
      if (accepted.files.keys.any((id) => !selected.containsKey(id))) {
        throw const WifiTransferException('The receiver returned an unknown file ID.');
      }
      final total = accepted.files.keys.fold<int>(0, (size, id) => size + selected[id]!.size);
      int submitted = 0;
      int completed = 0;
      onProgress(0, total);
      for (final entry in accepted.files.entries) {
        _checkCanceled();
        final file = selected[entry.key]!;
        onStatus('Sending ${file.name} to ${info.alias}…');
        final upload = await _request('POST', _uri('upload', {'sessionId': accepted.sessionId, 'fileId': entry.key, 'token': entry.value}));
        upload.contentLength = file.size;
        upload.headers.set(HttpHeaders.contentTypeHeader, metadata[entry.key]!.lookupMime());
        final stream = file.path != null ? File(file.path!).openRead() : Stream<List<int>>.value(file.bytes!);
        await _guard(upload.addStream(stream.map((chunk) {
          _checkCanceled();
          submitted += chunk.length;
          onProgress(submitted, total);
          return chunk;
        })));
        onStatus('Waiting for ${info.alias} to confirm ${file.name}…');
        final (status, _) = await _response(upload);
        _requireSuccess(status);
        completed++;
      }
      return WifiTransferResult(info.alias, completed, files.length - completed);
    } catch (error) {
      if (_sessionId != null || _offerPending) await _notifyCancel();
      if (_cancellation.isCompleted) throw const WifiTransferCancelled();
      rethrow;
    } finally {
      _client?.close(force: true);
    }
  }

  Future<void> _notifyCancel() async {
    final client = _createClient();
    try {
      await (() async {
        final request = await client.postUrl(_uri('cancel', {if (_sessionId != null) 'sessionId': _sessionId!}));
        request.followRedirects = false;
        final response = await request.close();
        await response.drain<void>();
      })()
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // A lost Wi-Fi connection must not fall back to any other interface.
    } finally {
      client.close(force: true);
    }
  }
}
