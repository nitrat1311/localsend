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

class WifiIpv4Interface {
  final String address;
  final int prefixLength;

  const WifiIpv4Interface(this.address, this.prefixLength);

  bool containsPeer(String peer) {
    if (!isUsableWifiAddress(address) || !isUsableWifiAddress(peer) || peer == address || prefixLength < 1 || prefixLength > 32) {
      return false;
    }
    int number(String value) => InternetAddress(value).rawAddress.fold(0, (n, byte) => (n << 8) | byte);
    final mask = (0xffffffff << (32 - prefixLength)) & 0xffffffff;
    final peerNumber = number(peer);
    final network = number(address) & mask;
    // Exclude network and broadcast addresses on ordinary LAN subnets.
    return (peerNumber & mask) == network && (prefixLength >= 31 || (peerNumber != network && peerNumber != (network | (~mask & 0xffffffff))));
  }
}

Future<List<WifiIpv4Interface>> getWindowsWifiInterfaces() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return [];
  try {
    final values = await wifiAddressChannel.invokeListMethod<dynamic>('getWifiIpv4Interfaces');
    return [
      for (final value in values ?? [])
        if (value is Map && value['address'] is String && value['prefixLength'] is int)
          WifiIpv4Interface(value['address'] as String, value['prefixLength'] as int),
    ].where((value) => isUsableWifiAddress(value.address) && value.prefixLength >= 1 && value.prefixLength <= 32).toList();
  } on PlatformException {
    return [];
  } on MissingPluginException {
    return [];
  }
}

String selectWifiAddressForPeer(List<WifiIpv4Interface> interfaces, String peer) {
  for (final network in interfaces) {
    if (network.containsPeer(peer)) return network.address;
  }
  throw StateError('The iPhone address is not on an active Wi-Fi subnet. Connect both devices to the same Wi-Fi and check its IP address.');
}

Future<String> resolveWifiAddressForPeer(String peer) async => selectWifiAddressForPeer(await getWindowsWifiInterfaces(), peer);
