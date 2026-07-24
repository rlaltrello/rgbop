import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

class SpotifyAuthCallback {
  const SpotifyAuthCallback({required this.uri, required this.refreshToken});

  final Uri uri;
  final String refreshToken;
}

class SpotifyAuthCallbackController {
  SpotifyAuthCallbackController._();

  static final SpotifyAuthCallbackController instance =
      SpotifyAuthCallbackController._();

  final AppLinks _appLinks = AppLinks();
  final ValueNotifier<SpotifyAuthCallback?> latestCallback =
      ValueNotifier<SpotifyAuthCallback?>(null);

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      _handleUri(await _appLinks.getInitialLink());
    } catch (error, stackTrace) {
      debugPrint('Failed to read initial Spotify auth callback: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Spotify auth link stream error: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
  }

  void clearLatestCallback(Uri uri) {
    final current = latestCallback.value;
    if (current?.uri.toString() == uri.toString()) {
      latestCallback.value = null;
    }
  }

  void _handleUri(Uri? uri) {
    if (uri == null) return;
    if (uri.scheme != 'rgbop' || uri.host != 'spotify-callback') return;

    final refreshToken = uri.queryParameters['refresh_token'];
    if (refreshToken == null || refreshToken.isEmpty) return;

    latestCallback.value = SpotifyAuthCallback(
      uri: uri,
      refreshToken: refreshToken,
    );
  }
}
