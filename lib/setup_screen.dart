import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_palette.dart';
import 'provisioning_provider.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _ssidController;
  late final TextEditingController _passController;
  
  // 1. Keep Provider instance stable across rebuilds
  late final ProvisioningProvider _provisioningProvider;

  // Track password visibility state
  bool _obscurePassword = true;

  void _triggerInitialScan() {
    try {
      (_provisioningProvider as dynamic).startScan();
      return;
    } catch (_) {}

    try {
      (_provisioningProvider as dynamic).scanForDevices();
      return;
    } catch (_) {}

    try {
      (_provisioningProvider as dynamic).beginScan();
      return;
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _ssidController = TextEditingController();
    _passController = TextEditingController();
    _provisioningProvider = ProvisioningProvider();
    // Wait for post-frame rendering + 800ms for BLE hardware to advertise
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          _triggerInitialScan();
        }
      });
    });
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passController.dispose();
    _provisioningProvider.dispose(); // Safely close BLE/connections on exit
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 2. ChangeNotifierProvider.value uses the STABLE instance from initState
    return ChangeNotifierProvider.value(
      value: _provisioningProvider,
      child: Scaffold(
        backgroundColor: AppPalette.surfacePage,
        appBar: AppBar(
          leadingWidth: 130,
          leading: TextButton.icon(
            onPressed: () => Navigator.pushReplacementNamed(context, '/'),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to Wi-Fi'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.only(left: 8),
            ),
          ),
          title: const Text("RGBop Setup"),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Consumer<ProvisioningProvider>(
          builder: (context, provider, child) {
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // --- Status Icon ---
                    Icon(
                      provider.isConnected
                          ? Icons.check_circle_outline
                          : Icons.bluetooth_searching,
                      size: 80,
                      color: provider.isConnected
                          ? AppPalette.statusSuccess
                          : AppPalette.brandAccent,
                    ),
                    const SizedBox(height: 24),

                    // --- Status Text ---
                    Text(
                      provider.statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white70,
                      ),
                    ),
                    if (!provider.isConnected &&
                        provider.candidateDeviceIds.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        "Select Provisioning Device",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ...provider.candidateDeviceIds.map(
                        (id) => Card(
                          color: AppPalette.overlayWhite10,
                          child: ListTile(
                            leading: const Icon(
                              Icons.memory,
                              color: AppPalette.brandAccent,
                            ),
                            title: const Text(
                              "RGBop-Setup",
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              id,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            trailing: const Icon(
                              Icons.login,
                              color: AppPalette.brandAccent,
                            ),
                            onTap: provider.isScanning
                                ? null
                                : () => provider.connectToCandidate(id),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: provider.isScanning
                            ? null
                            : provider.retryScan,
                        icon: const Icon(Icons.refresh),
                        label: const Text("Rescan"),
                      ),
                    ],
                    const SizedBox(height: 40),

                    // --- The Wi-Fi Form (Only shows when connected via BLE) ---
                    if (provider.isConnected) ...[
                      TextField(
                        controller: _ssidController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Wi-Fi Network Name",
                          labelStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: AppPalette.overlayWhite10,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // --- Password Field with Eyeball Toggle ---
                      TextField(
                        controller: _passController,
                        obscureText: _obscurePassword,
                        enableSuggestions: false,
                        autocorrect: false,
                        textCapitalization: TextCapitalization.none,
                        keyboardType: TextInputType.visiblePassword,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Wi-Fi Password",
                          labelStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: AppPalette.overlayWhite10,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: Colors.white54,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // --- Submit Button ---
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppPalette.brandAccent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: provider.isSending
                            ? null
                            : () async {
                                bool success = await provider.provisionPanel(
                                  _ssidController.text,
                                  _passController.text,
                                );

                                if (success) {
                                  await Future.delayed(
                                    const Duration(seconds: 2),
                                  );

                                  if (!context.mounted) return;

                                  Navigator.pushReplacementNamed(context, '/');
                                }
                              },
                        child: provider.isSending
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Text(
                                "Send to Panel",
                                style: TextStyle(fontSize: 18),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}