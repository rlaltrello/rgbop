import 'package:flutter/material.dart';
import 'app_palette.dart';

class PanelStorageInfo {
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;

  const PanelStorageInfo({
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
  });

  factory PanelStorageInfo.fromJson(Map<dynamic, dynamic> json) {
    return PanelStorageInfo(
      totalBytes: _asInt(json['total']),
      usedBytes: _asInt(json['used']),
      freeBytes: _asInt(json['free']),
    );
  }

  double get fullness {
    if (totalBytes <= 0) return 0;
    final value = usedBytes / totalBytes;
    return value.clamp(0, 1).toDouble();
  }

  int get percentFull => (fullness * 100).round();

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class PanelStorageCard extends StatelessWidget {
  final PanelStorageInfo info;

  const PanelStorageCard({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final progressColor = info.percentFull >= 90
        ? AppPalette.statusDanger
        : info.percentFull >= 75
        ? AppPalette.statusWarning
        : AppPalette.brandAccent;
    final accentBackground = info.percentFull >= 90
        ? const Color(0x33FF5252)
        : info.percentFull >= 75
        ? const Color(0x33FFC107)
        : const Color(0x221E88E5);
    final borderColor = info.percentFull >= 90
        ? const Color(0x66FF5252)
        : info.percentFull >= 75
        ? const Color(0x66FFC107)
        : AppPalette.overlayWhite10;
    final statusLabel = info.percentFull >= 90
        ? 'Nearly full'
        : info.percentFull >= 75
        ? 'Getting tight'
        : 'Healthy';
    final statusText = info.percentFull >= 90
        ? 'Storage is almost exhausted. Syncs and uploads may fail soon.'
        : info.percentFull >= 75
        ? 'Available space is shrinking. Consider clearing large files soon.'
        : 'You still have comfortable headroom for uploads and syncs.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.surfaceCard, accentBackground],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: progressColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.storage_rounded, color: progressColor),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Panel Storage',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'LittleFS usage on the connected panel',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: progressColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${info.percentFull}% full',
                  style: TextStyle(
                    color: progressColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: accentBackground,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: progressColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  statusText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: info.fullness,
              minHeight: 10,
              color: progressColor,
              backgroundColor: AppPalette.overlayWhite12,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _StorageStat(
                  label: 'Used',
                  value: _formatBytes(info.usedBytes),
                  color: progressColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StorageStat(
                  label: 'Free',
                  value: _formatBytes(info.freeBytes),
                  color: AppPalette.statusSuccess,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StorageStat(
                  label: 'Total',
                  value: _formatBytes(info.totalBytes),
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

class PanelStorageSection extends StatefulWidget {
  final PanelStorageInfo info;

  const PanelStorageSection({super.key, required this.info});

  @override
  State<PanelStorageSection> createState() => _PanelStorageSectionState();
}

class _PanelStorageSectionState extends State<PanelStorageSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final toneColor = widget.info.percentFull >= 90
        ? AppPalette.statusDanger
        : widget.info.percentFull >= 75
        ? AppPalette.statusWarning
        : AppPalette.brandAccent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppPalette.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppPalette.overlayWhite10),
            ),
            child: Row(
              children: [
                Icon(Icons.storage_rounded, color: toneColor, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Storage Info',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${widget.info.percentFull}% full',
                  style: TextStyle(
                    color: toneColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white70,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(height: 0),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: PanelStorageCard(info: widget.info),
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
        ),
      ],
    );
  }
}

class _StorageStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StorageStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
