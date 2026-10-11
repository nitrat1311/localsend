import 'package:common/isolate.dart';
import 'package:common/model/device.dart';
import 'package:common/model/device_info_result.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:localsend_app/config/link_only.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  test('Every discovery action is inert even when called directly', () async {
    final service = ReduxNotifier.test(
      redux: NearbyDevicesService(
        isolateController: IsolateController(
          initialState: ParentIsolateState.initial(SyncState(
            init: () async {},
            rootIsolateToken: Object(),
            httpClientFactory: (_, __) => throw StateError('Unexpected network request'),
            securityContext: const StoredSecurityContext(privateKey: '', publicKey: '', certificate: '', certificateHash: ''),
            deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: null, androidSdkInt: null),
            alias: 'Link-only test',
            port: 53317,
            protocol: ProtocolType.http,
            multicastGroup: '224.0.0.167',
            discoveryTimeout: 500,
            serverRunning: false,
            download: false,
          )),
        ),
        favoriteService: FavoritesService(MockPersistenceService()),
        discoveryLogs: DiscoveryLogger(),
      ),
    );
    service.dispatch(StartMulticastScan());
    await service.dispatchAsync(StartMulticastListener());
    await service.dispatchAsync(StartLegacyScan(port: 53317, localIp: '192.168.50.5', https: false));
    await service.dispatchAsync(StartFavoriteScan(devices: [
      FavoriteDevice(id: 'test', ip: '192.168.50.10', port: 53317, fingerprint: 'test', alias: 'test', customAlias: false),
    ], https: false));
    expect(service.state.devices, isEmpty);
    expect(service.state.runningIps, isEmpty);
    expect(service.state.runningFavoriteScan, isFalse);
  }, skip: !linkOnlyMode);

  test('Scan facade does not even initialize networking providers', () async {
    final container = RefenaContainer();
    await container.global.dispatchAsync(StartSmartScan(forceLegacy: false));
    await container.global.dispatchAsync(StartSmartScan(forceLegacy: true));
    await container.global.dispatchAsync(StartLegacySubnetScan(subnets: ['192.168.50.5']));
    container.disposeContainer();
  }, skip: !linkOnlyMode);
}
