import 'package:flutter/material.dart';
import 'rgbop_ble_service.dart'; // The file we created earlier

class ProvisioningProvider extends ChangeNotifier {
  final RGBopBleService _bleService = RGBopBleService();

  bool isScanning = false;
  bool isConnected = false;
  bool isSending = false;
  String statusMessage = "Looking for RGBop panels...";
  List<String> candidateDeviceIds = const [];

  ProvisioningProvider() {
    // Start scanning the moment the provider is initialized
    _startProvisioningFlow();
  }

  Future<void> _startProvisioningFlow() async {
    isScanning = true;
    notifyListeners();

    try {
      final devices = await _bleService.scanForRGBop();
      candidateDeviceIds = devices.map((d) => d.remoteId.str).toList();

      if (devices.isEmpty) {
        statusMessage = "No provisioning panel found. Power cycle board and retry.";
        isScanning = false;
        notifyListeners();
        return;
      }

      if (devices.length == 1) {
        await connectToCandidate(devices.first.remoteId.str);
        return;
      }

      statusMessage = "Multiple panels found. Select one by device ID.";
      isScanning = false;
      notifyListeners();

    } catch (e) {
      statusMessage = "Connection failed. Please try again.";
      isScanning = false;
      notifyListeners();
    }
  }

  Future<void> retryScan() async {
    isConnected = false;
    isSending = false;
    candidateDeviceIds = const [];
    statusMessage = "Looking for RGBop panels...";
    notifyListeners();
    await _startProvisioningFlow();
  }

  Future<void> connectToCandidate(String deviceId) async {
    isScanning = true;
    statusMessage = "Connecting to panel $deviceId...";
    notifyListeners();

    try {
      final devices = await _bleService.scanForRGBop(timeout: const Duration(seconds: 6));
      final match = devices.where((d) => d.remoteId.str == deviceId).toList();
      if (match.isEmpty) {
        isScanning = false;
        statusMessage = "Selected panel not found. Keep only target panel powered, then retry.";
        notifyListeners();
        return;
      }

      await _bleService.connectToDevice(match.first);
      _bleService.targetDevice = match.first;
      isConnected = true;
      isScanning = false;
      statusMessage = "Connected!";
      notifyListeners();
    } catch (e) {
      isScanning = false;
      statusMessage = "Connection failed. Please try again.";
      notifyListeners();
    }
  }

  Future<bool> provisionPanel(String ssid, String password) async {
    isSending = true;
    statusMessage = "Sending credentials...";
    notifyListeners();

    bool success = await _bleService.sendCredentials(ssid, password);

    isSending = false;
    if (success) {
      statusMessage = "Credentials sent! Panel is rebooting...";
    } else {
      statusMessage = "Failed to send. Check connection.";
    }
    notifyListeners();
    
    return success;
  }
}