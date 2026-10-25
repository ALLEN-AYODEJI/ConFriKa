import 'dart:async';

import 'package:flutter/material.dart';

import 'core/services/ads_service.dart';
import 'core/services/audio_service.dart';
import 'core/services/callkit_service.dart';
import 'core/session.dart';
import 'core/theme/confrika_theme.dart';
import 'features/auth/auth_screen.dart';
import 'features/shell/confrika_shell.dart';
import 'features/splash/confrika_splash.dart';

void main() {
  // Guard the whole startup so no single service (ads, push, callkit, a device
  // without a given capability) can prevent the UI from rendering. The app must
  // always reach runApp, even if an initializer throws.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) => FlutterError.presentError(details);

    // Non-critical startup tasks — each isolated so a failure is survivable.
    try {
      ConFriKaCallKitService().initialize();
    } catch (e) {
      debugPrint('CallKit init failed (non-fatal): $e');
    }
    try {
      ConFriKaAudioService().initialize();
    } catch (e) {
      debugPrint('Audio init failed (non-fatal): $e');
    }
    try {
      AdsService.instance.init(); // non-blocking; ads only shown to free users
    } catch (e) {
      debugPrint('Ads init failed (non-fatal): $e');
    }
    try {
      await ConFriKaSession.instance.load();
    } catch (e) {
      debugPrint('Session load failed (non-fatal): $e');
    }

    runApp(const ConFriKaApp());
  }, (error, stack) {
    // Last-resort guard: never let an uncaught async error kill startup silently.
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}

class ConFriKaApp extends StatefulWidget {
  const ConFriKaApp({super.key});

  @override
  State<ConFriKaApp> createState() => _ConFriKaAppState();
}

class _ConFriKaAppState extends State<ConFriKaApp> {
  bool _isDarkMode = false;
  bool _showSplash = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ConFriKa · Connect Africa',
      debugShowCheckedModeBanner: false,
      theme: ConFriKaTheme.lightTheme,
      darkTheme: ConFriKaTheme.darkTheme,
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child: _showSplash
            ? ConFriKaSplash(
                key: const ValueKey('splash'),
                onDone: () => setState(() => _showSplash = false),
              )
            : AnimatedBuilder(
                key: const ValueKey('app'),
                animation: ConFriKaSession.instance,
                builder: (context, _) {
                  if (!ConFriKaSession.instance.isAuthenticated) {
                    return const ConFriKaAuthScreen();
                  }
                  return ConFriKaShell(
                    isDarkMode: _isDarkMode,
                    onToggleThemeMode: () =>
                        setState(() => _isDarkMode = !_isDarkMode),
                  );
                },
              ),
      ),
    );
  }
}
