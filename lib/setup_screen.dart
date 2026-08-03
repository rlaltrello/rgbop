import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_palette.dart';
import 'provisioning_provider.dart';

class SetupScreen extends StatelessWidget {
  SetupScreen({super.key});

  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ProvisioningProvider(),
      child: Scaffold(
        backgroundColor: AppPalette.surfacePage, // Dark, sleek appliance vibe
        appBar: AppBar(
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
                      TextField(
                        controller: _passController,
                        obscureText: true,
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
                                  // 1. Wait for 2 seconds to let the board reboot
                                  await Future.delayed(
                                    const Duration(seconds: 2),
                                  );

                                  // 2. The crucial safety check!
                                  // If the user closed the app during those 2 seconds, stop here.
                                  if (!context.mounted) return;

                                  // 3. Safe to navigate
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/dashboard',
                                  );
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
