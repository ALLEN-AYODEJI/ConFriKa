/// App-wide configuration.
///
/// The backend base URL defaults to the live Fly.io backend. For local
/// development against a backend on the host, override at build time with the
/// Android-emulator loopback alias (10.0.2.2 maps to the host's localhost):
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8088
/// Switch the default to https://api.confrika.online once that custom domain
/// is pointed at the Fly app.
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://confrika-backend.fly.dev',
  );

  /// WebSocket base derived from the API base URL (http->ws, https->wss).
  static String get wsBaseUrl {
    if (apiBaseUrl.startsWith('https')) {
      return apiBaseUrl.replaceFirst('https', 'wss');
    }
    return apiBaseUrl.replaceFirst('http', 'ws');
  }
}
