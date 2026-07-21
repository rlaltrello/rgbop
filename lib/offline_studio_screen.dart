import 'package:flutter/material.dart';

import 'doodle_gallery.dart';
import 'gif_manager_screen.dart';

class OfflineStudioScreen extends StatelessWidget {
  const OfflineStudioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Studio')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: const Text(
              'Create and organize local content while away from your panel. '
              'Remote actions (sync/import/toggle) are unavailable until you reconnect.',
              style: TextStyle(color: Colors.white70, height: 1.35),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFF1E1E1E),
            child: ListTile(
              leading: const Icon(Icons.gif_box, color: Colors.blueAccent),
              title: const Text(
                'Manage GIFs (Offline)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('Local GIF library only'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const GifManagerScreen(offlineMode: true),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: const Color(0xFF1E1E1E),
            child: ListTile(
              leading: const Icon(Icons.brush, color: Colors.blueAccent),
              title: const Text(
                'Manage Doodles (Offline)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('Create/edit local doodles only'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DoodleGallery(offlineMode: true),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
