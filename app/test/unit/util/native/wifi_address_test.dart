import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/link_only.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/native/wifi_address.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(wifiAddressChannel, null);
  });

  test('Uses only native Wi-Fi addresses and removes unusable addresses', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(wifiAddressChannel, (call) async {
      expect(call.method, 'getWifiIpv4');
      return ['192.168.50.5', '0.0.0.0', '127.0.0.1', '169.254.4.5', '224.0.0.167', '::1', 'bad', '192.168.50.5'];
    });
    expect(await getWindowsWifiAddresses(), ['192.168.50.5']);
  });

  test('Native failure leaves no address and refuses wildcard binding', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(wifiAddressChannel, (_) async {
      throw PlatformException(code: 'wifi_unavailable');
    });
    expect(await getWindowsWifiAddresses(), isEmpty);
    expect(() => requireWifiAddress([]), throwsStateError);
    expect(() => requireWifiAddress(['0.0.0.0']), throwsStateError);
  });

  test('Missing native channel cannot fall back to another adapter', () async {
    expect(await getWindowsWifiAddresses(), isEmpty);
  });

  test('Non-Windows platforms fail closed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await getWindowsWifiAddresses(), isEmpty);
  });

  test('Uses the first usable address, including hotspot .1 addresses', () {
    expect(requireWifiAddress(['192.168.137.1', '192.168.50.5']), '192.168.137.1');
  });

  test('HTTP and HTTPS server startup both refuse to bind without Wi-Fi', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(wifiAddressChannel, (_) async => <String>[]);
    final service = Notifier.test(notifier: ServerService());
    for (final encrypted in [false, true]) {
      await expectLater(service.notifier.startServer(alias: 'Test', port: 53317, https: encrypted), throwsStateError);
      expect(service.state, isNull);
      expect(service.notifier.boundAddress, isNull);
    }
  }, skip: !linkOnlyMode || outgoingOnlyMode);

  test('Outgoing edition cannot start a PC server, even through a manual action', () async {
    final service = Notifier.test(notifier: ServerService());
    for (final encrypted in [false, true]) {
      expect(await service.notifier.startServer(alias: 'Test', port: 53317, https: encrypted), isNull);
      expect(service.state, isNull);
      expect(service.notifier.boundAddress, isNull);
    }
  }, skip: !outgoingOnlyMode);

  test('Selects only a matching Wi-Fi subnet using the actual prefix', () {
    const interfaces = [WifiIpv4Interface('10.10.0.2', 16), WifiIpv4Interface('192.168.50.5', 24)];
    expect(selectWifiAddressForPeer(interfaces, '10.10.40.20'), '10.10.0.2');
    expect(selectWifiAddressForPeer(interfaces.reversed.toList(), '10.10.40.20'), '10.10.0.2');
    expect(selectWifiAddressForPeer(interfaces, '192.168.50.9'), '192.168.50.5');
    for (final peer in ['192.168.51.9', '192.168.50.0', '192.168.50.255', '192.168.50.5', '127.0.0.1', '::1', 'bad']) {
      expect(() => selectWifiAddressForPeer(interfaces, peer), throwsStateError);
    }
    expect(() => selectWifiAddressForPeer([], '192.168.50.9'), throwsStateError);
    expect(() => selectWifiAddressForPeer([const WifiIpv4Interface('192.168.50.5', 0)], '192.168.50.9'), throwsStateError);
  });

  test('Loads native Wi-Fi prefixes and fails closed if missing', () async {
    expect(await getWindowsWifiInterfaces(), isEmpty);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(wifiAddressChannel, (call) async {
      expect(call.method, 'getWifiIpv4Interfaces');
      return [
        {'address': '192.168.50.5', 'prefixLength': 24},
        {'address': '127.0.0.1', 'prefixLength': 8},
        {'address': '10.0.0.1', 'prefixLength': 0},
        {'address': '10.0.0.2', 'prefixLength': 999},
        {'address': '10.0.0.3'},
      ];
    });
    final interfaces = await getWindowsWifiInterfaces();
    expect(interfaces, hasLength(1));
    expect(interfaces.single.address, '192.168.50.5');
    expect(interfaces.single.prefixLength, 24);
  });
}
