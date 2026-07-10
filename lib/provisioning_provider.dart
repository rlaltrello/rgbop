import 'package:flutter/material.dart';
import 'rgbop_ble_service.dart'; // The file we created earlier

class ProvisioningProvider extends ChangeNotifier {
  final RGBopBleService _bleService = RGBopBleService();

  bool isScanning = false;
  bool isConnected = false;
  bool isSending = false;
  String statusMessage = "Looking for RGBop panels...";

  ProvisioningProvider() {
    // Start scanning the moment the provider is initialized
    _startProvisioningFlow();
  }

  Future<void> _startProvisioningFlow() async {
    isScanning = true;
    notifyListeners();

    try {
      await _bleService.scanForRGBop();
      
      // We will loop and wait for the targetDevice to populate in the service
      // (In production, you'd want a cleaner stream listener here)
      while (_bleService.targetDevice == null) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      statusMessage = "Connecting to panel...";
      notifyListeners();

      await Future.delayed(const Duration(seconds: 1)); // Give the connection a second to settle
      
      isConnected = true;
      isScanning = false;
      statusMessage = "Connected!";
      notifyListeners();

    } catch (e) {
      statusMessage = "Connection failed. Please try again.";
      isScanning = false;
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