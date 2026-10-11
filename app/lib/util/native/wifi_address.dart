import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const wifiAddressChannel = MethodChannel('org.localsend/wifi_address');

/// Uses Windows adapter types, never adapter names or the default route.
/// Failure means no usable address; callers must not fall back to Ethernet.
Future<List<String>> getWindowsWifiAddresses() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    return [];
  }
  try {
    final addresses = await wifiAddressChannel.invokeListMethod<String>('getWifiIpv4');
    return (addresses ?? []).where(isUsableWifiAddress).toSet().toList();
  } on PlatformException {
    return [];
  } on MissingPluginException {
    return [];
  }
}

bool isUsableWifiAddress(String value) {
  final address = InternetAddress.tryParse(value);
  if (address == null || address.type != InternetAddressType.IPv4 || address.isLoopback || address.isMulticast) {
    return false;
  }
  final bytes = address.rawAddress;
  return bytes[0] != 0 && bytes[0] < 224 && !(bytes[0] == 169 && bytes[1] == 254);
}

/// Deliberately refuses wildcard binding when Wi-Fi is unavailable.
String requireWifiAddress(List<String> addresses) {
  final usable = addresses.where(isUsableWifiAddress);
  if (usable.isEmpty) {
    throw StateError('Connect to Wi-Fi, then retry Share via link. No Wi-Fi IPv4 address is available.');
  }
  return usable.first;
}
