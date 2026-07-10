import 'package:flutter/material.dart';
import 'setup_screen.dart'; // Make sure this path matches where you saved setup_screen.dart
import 'dashboard_screen.dart';

void main() {
  runApp(const RGBopApp());
}

class RGBopApp extends StatelessWidget {
  const RGBopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RGBop',
      debugShowCheckedModeBanner: false, // Removes the little "DEBUG" banner
      
      // We are going with a dark theme because it fits the hardware appliance vibe perfectly
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.blueAccent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
        useMaterial3: true,
      ),
      
      // Set the first screen of the app to our new SetupScreen
      initialRoute: '/',
      routes: {
        '/': (context) => SetupScreen(),
        '/dashboard': (context) => const DashboardScreen(),
      },
    );
  }
}