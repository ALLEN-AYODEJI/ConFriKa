import 'package:flutter/material.dart';

import 'core/services/ads_service.dart';
import 'core/services/audio_service.dart';
import 'core/services/callkit_service.dart';
import 'core/session.dart';
import 'core/theme/confrika_theme.dart';
import 'features/auth/auth_screen.dart';
import 'features/shell/confrika_shell.dart';
import 'features/splash/confrika_splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ConFriKaCallKitService().initialize();
  ConFriKaAudioService().initialize();
  AdsService.instance.init(); // non-blocking; ads only shown to free users
  await ConFriKaSession.instance.load();
  runApp(const ConFriKaApp());
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
