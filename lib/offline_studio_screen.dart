import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'doodle_gallery.dart';
import 'gif_manager_screen.dart';

class OfflineStudioScreen extends StatelessWidget {
  const OfflineStudioScreen({super.key});

  Widget _buildStudioTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      color: AppPalette.surfacePanel,
      elevation: 3,
      shadowColor: AppPalette.overlayScrim,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppPalette.overlayWhite12),
      ),
      child: ListTile(
        minTileHeight: 90,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppPalette.brandAccent.withValues(alpha: 0.2),
            shape: BoxShape.circle,
            border: Border.all(color: AppPalette.overlayWhite12),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: AppPalette.brandAccent),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.82),
            ),
          ),
        ),
        trailing: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppPalette.brandAccent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.chevron_right, color: AppPalette.brandAccent),
        ),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Offline Studio')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppPalette.surfacePanel.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppPalette.overlayWhite12),
            ),
            child: Text(
              'Create and organize local content while away from your panel. '
              'Remote actions (sync/import/toggle) are unavailable until you reconnect.',
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.88),
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _buildStudioTile(
            context: context,
            icon: Icons.gif_box,
            title: 'Manage GIFs (Offline)',
            subtitle: 'Local GIF library only',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const GifManagerScreen(offlineMode: true),
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          _buildStudioTile(
            context: context,
            icon: Icons.brush,
            title: 'Manage Doodles (Offline)',
            subtitle: 'Create/edit local doodles only',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DoodleGallery(offlineMode: true),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
