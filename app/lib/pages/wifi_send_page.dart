import 'dart:async';

import 'package:common/constants.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/native/wifi_address.dart';
import 'package:localsend_app/util/wifi_direct_sender.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WifiSendPage extends StatefulWidget {
  final List<CrossFile> files;
  const WifiSendPage(this.files);

  @override
  State<WifiSendPage> createState() => _WifiSendPageState();
}

class _WifiSendPageState extends State<WifiSendPage> {
  final _form = GlobalKey<FormState>();
  final _ip = TextEditingController();
  final _port = TextEditingController(text: '53317');
  final _pin = TextEditingController();
  bool _https = true;
  bool _busy = false;
  bool _failed = false;
  String _status = '';
  double? _progress;
  WifiDirectSender? _sender;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_loadEndpoint());
  }

  Future<void> _loadEndpoint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _busy || _ip.text.isNotEmpty) return;
    setState(() {
      _ip.text = prefs.getString('wifiSenderIp') ?? '';
      _port.text = (prefs.getInt('wifiSenderPort') ?? 53317).toString();
      _https = prefs.getBool('wifiSenderHttps') ?? true;
    });
  }

  @override
  void dispose() {
    _sender?.cancel();
    _ip.dispose();
    _port.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _failed = false;
      _progress = null;
      _status = 'Checking the Wi-Fi connection…';
    });
    final ref = context.ref;
    final settings = ref.read(settingsProvider);
    final deviceInfo = ref.read(deviceInfoProvider);
    final security = ref.read(securityProvider);
    final sender = WifiDirectSender(
      phoneIp: _ip.text.trim(),
      port: int.parse(_port.text.trim()),
      https: _https,
      securityContext: security,
      senderInfo: InfoRegisterDto(
        alias: settings.alias,
        version: protocolVersion,
        deviceModel: deviceInfo.deviceModel,
        deviceType: deviceInfo.deviceType,
        fingerprint: security.certificateHash,
        // No PC receiver is available; don't advertise a callback listener.
        port: null,
        protocol: ProtocolType.https,
        download: false,
      ),
    );
    _sender = sender;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wifiSenderIp', sender.phoneIp);
      await prefs.setInt('wifiSenderPort', sender.port);
      await prefs.setBool('wifiSenderHttps', sender.https);
      final result = await sender.send(
        files: widget.files,
        pin: _pin.text.trim(),
        onStatus: (message) {
          if (mounted) setState(() => _status = message);
        },
        onProgress: (sent, total) {
          final now = DateTime.now();
          if (!mounted || (sent != total && now.difference(_lastProgress).inMilliseconds < 150)) return;
          _lastProgress = now;
          setState(() => _progress = total == 0 ? 0 : (sent / total).clamp(0, 1));
        },
      );
      if (!mounted) return;
      setState(() {
        _progress = 1;
        _status = result.sentFiles == 0
            ? 'The iPhone accepted the message or selected no files for download.'
            : 'Sent ${result.sentFiles} file(s) to ${result.receiverAlias}.';
        if (result.skippedFiles > 0 && result.sentFiles > 0) _status += ' ${result.skippedFiles} file(s) were not selected on the iPhone.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _progress = null;
        _status = switch (error) {
          WifiTransferCancelled() => 'Transfer canceled. Dismiss any pending offer on the iPhone before retrying.',
          WifiTransferException() => error.message,
          TimeoutException() => 'The iPhone did not respond in time. Keep LocalSend open and accept the offer. Check its address and port.',
          _ => 'Could not send: $error\nKeep LocalSend open on the iPhone, allow Local Network access, and check the address and encryption setting.',
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _sender = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Send to iPhone')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  '1. Open LocalSend on your iPhone and allow Local Network access. Keep the app open and the screen awake.\n'
                  '2. Connect the iPhone and PC to the same Wi-Fi.\n'
                  '3. On iPhone: Settings → Wi-Fi → ⓘ next to your network → IP Address. Enter that address below.\n'
                  '4. Click Send, then tap Accept in LocalSend on the iPhone.',
                ),
                const SizedBox(height: 20),
                Text('${widget.files.length} selected file(s) • ${widget.files.fold<int>(0, (sum, file) => sum + file.size).asReadableFileSize}'),
                const SizedBox(height: 20),
                Form(
                  key: _form,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _ip,
                        enabled: !_busy,
                        decoration: const InputDecoration(labelText: 'iPhone Wi-Fi IP address', hintText: '192.168.1.25'),
                        validator: (value) => isUsableWifiAddress(value?.trim() ?? '') ? null : 'Enter a Wi-Fi IPv4 address, such as 192.168.1.25.',
                      ),
                      const SizedBox(height: 16),
                      ExpansionTile(
                        title: const Text('PIN, port and encryption'),
                        children: [
                          TextFormField(
                            controller: _pin,
                            enabled: !_busy,
                            obscureText: true,
                            decoration: const InputDecoration(labelText: 'iPhone receive PIN (only if configured)'),
                          ),
                          TextFormField(
                            controller: _port,
                            enabled: !_busy,
                            decoration: const InputDecoration(labelText: 'iPhone LocalSend port'),
                            validator: (value) {
                              final port = int.tryParse(value?.trim() ?? '');
                              return port != null && port >= 1 && port <= 65535 ? null : 'Enter a port from 1 to 65535.';
                            },
                          ),
                          SwitchListTile(
                            title: const Text('HTTPS encryption'),
                            subtitle: const Text('Match the Encryption setting in LocalSend on the iPhone.'),
                            value: _https,
                            onChanged: _busy ? null : (value) => setState(() => _https = value),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                if (_busy || _progress != null) LinearProgressIndicator(value: _progress),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(_status, style: _failed ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
                ],
                const SizedBox(height: 20),
                if (_busy)
                  OutlinedButton(onPressed: () => _sender?.cancel(), child: const Text('Cancel'))
                else
                  FilledButton.icon(onPressed: _send, icon: const Icon(Icons.send), label: const Text('Send to iPhone')),
                const SizedBox(height: 16),
                const Text('Keep Windows Firewall enabled. This mode needs no administrator rights or incoming firewall exception.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
