import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class RGBopBleService {
  // These UUIDs must match your ESP32 NimBLE configuration exactly
  static const String provServiceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String ssidCharUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const String passCharUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a9";
  static const String cmdCharUuid = "beb5483e-36e1-4688-b7f5-ea07361b26aa";

  BluetoothDevice? targetDevice;

  // 1. Scan for candidate RGBop panels and return unique devices.
  Future<List<BluetoothDevice>> scanForRGBop({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    // Check if the physical Bluetooth radio is turned on
    debugPrint("[BLE] Waiting for iOS Bluetooth manager to wake up...");
    
    // Wait until the adapter state explicitly reports 'on' before continuing
    await FlutterBluePlus.adapterState
        .where((state) => state == BluetoothAdapterState.on)
        .first;
        
    debugPrint("[BLE] Adapter is ON. Proceeding with scan.");

    debugPrint("[BLE] Starting targeted scan for RGBop provisioning devices...");
    
    // We filter the scan explicitly by our custom Service UUID 
    // so the app ignores random headphones, TVs, or beacons nearby.
    //await FlutterBluePlus.startScan(
     // withServices: [Guid(provServiceUuid)],
     // timeout: const Duration(seconds: 15),
    //);
    final candidates = <String, BluetoothDevice>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        
        // --- DIAGNOSTIC RADAR SWEEP ---
        // This will flood your console with every TV, Apple Watch, and BLE beacon in the house.
        // It proves whether the phone is actually seeing the ESP32.
        debugPrint("[BLE Radar] Seen: '${r.device.platformName}' | AdvName: '${r.advertisementData.advName}' | UUIDs: ${r.advertisementData.serviceUuids}");

        // We now check for the Name OR our specific Service UUID
        if (r.device.platformName == "RGBop-Setup" ||
            r.advertisementData.advName == "RGBop-Setup" ||
            r.advertisementData.serviceUuids.contains(Guid(provServiceUuid))) {

          final id = r.device.remoteId.str;
          if (!candidates.containsKey(id)) {
            debugPrint("[BLE] Candidate panel found: ${r.device.platformName} (${r.device.remoteId})");
          }
          candidates[id] = r.device;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: timeout);

    // Add a tiny grace window so late results are processed after the timeout.
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Ignore if already stopped by the platform timeout.
    }
    await sub.cancel();

    final found = candidates.values.toList();
    debugPrint("[BLE] Scan complete. Found ${found.length} candidate panel(s).");
    return found;
  }

  // 2. Establish the BLE connection
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      debugPrint("[BLE] Attempting connection to ${device.platformName}...");
      await device.connect(license: License.nonprofit, autoConnect: false);
      debugPrint("[BLE] Connected successfully.");
      
      // Android default MTU is tiny (23 bytes). Request a larger buffer
      // so long Wi-Fi network keys don't get truncated during transmission.
      if (Platform.isAndroid) {
        debugPrint("[BLE] Requesting expanded MTU for Android pipeline...");
        await device.requestMtu(256); 
      }
    } catch (e) {
      debugPrint("[BLE] Connection error: $e");
      rethrow;
    }
  }

  // 3. Transmit Wi-Fi Credentials over GATT
  Future<bool> sendCredentials(String ssid, String password) async {
    if (targetDevice == null) {
      debugPrint("[BLE] Cannot send credentials: No active panel device target.");
      return false;
    }

    try {
      debugPrint("[BLE] Discovering GATT Services on target...");
      List<BluetoothService> services = await targetDevice!.discoverServices();
      
      // Isolate the provisioning service block
      BluetoothService provService = services.firstWhere(
        (s) => s.uuid == Guid(provServiceUuid),
        orElse: () => throw Exception("RGBop Provisioning Service not found on board."),
      );

      var chars = provService.characteristics;
      
      // Map the specific characteristics
      BluetoothCharacteristic ssidChar = chars.firstWhere((c) => c.uuid == Guid(ssidCharUuid));
      BluetoothCharacteristic passChar = chars.firstWhere((c) => c.uuid == Guid(passCharUuid));
      BluetoothCharacteristic cmdChar = chars.firstWhere((c) => c.uuid == Guid(cmdCharUuid));

      // Write network name (UTF-8 bytes)
      debugPrint("[BLE] Transmitting SSID: $ssid");
      await ssidChar.write(utf8.encode(ssid), withoutResponse: false);
      
      await Future.delayed(const Duration(milliseconds: 500));

      // Write network password (UTF-8 bytes)
      debugPrint("[BLE] Transmitting Password payload...");
      await passChar.write(utf8.encode(password), withoutResponse: false);

      await Future.delayed(const Duration(milliseconds: 500));

      // Write the execution flag byte (0x01) to tell the firmware loop 
      // to drop the BLE radio and execute the Wi-Fi connection attempt
      debugPrint("[BLE] Transmitting connection trigger command byte...");
      await cmdChar.write([0x01], withoutResponse: false);
      
      debugPrint("[BLE] Waiting 12 seconds for ESP32 hardware reboot...");
      await Future.delayed(const Duration(seconds: 12));
      
      return true;
    } catch (e) {
      debugPrint("[BLE] Critical error during credential payload transmission: $e");
      return false;
    }
  }
}