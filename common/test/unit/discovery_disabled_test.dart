import 'package:common/isolate.dart';
import 'package:common/model/device.dart';
import 'package:common/model/device_info_result.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/stored_security_context.dart';
import 'package:refena/refena.dart';
import 'package:test/test.dart';

void main() {
  test('Disabled discovery does not create UDP or HTTP discovery workers', () async {
    final service = ReduxNotifier.test(
      redux: IsolateController(
        initialState: ParentIsolateState.initial(SyncState(
          init: () async {},
          rootIsolateToken: Object(),
          httpClientFactory: (_, __) => throw StateError('Discovery must not create an HTTP client'),
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
    );
    try {
      await service.dispatchAsync(IsolateSetupAction(uriContentStreamResolver: null, discoveryEnabled: false));
      expect(service.state.multicastDiscovery, isNull);
      expect(service.state.httpScanDiscovery, isNull);
      expect(service.state.httpTargetDiscovery, isNull);
      expect(service.state.httpUpload, hasLength(2));
    } finally {
      service.dispatch(IsolateDisposeAction());
    }
  });
}
