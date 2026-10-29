import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';

/// Live-camera sign recognition for mobile.
///
/// Runs MediaPipe Hands + the same geometric recognizer the backend and the
/// browser extension use, inside an in-app WebView. The page is served over the
/// WebView's localhost server (a secure context, which `getUserMedia` requires)
/// and the MediaPipe runtime is loaded from a CDN. Recognized whole words are
/// posted back to Flutter via a JS handler so the app can speak them.
class LiveSignView extends StatefulWidget {
  final ValueChanged<String> onWord;
  final ValueChanged<String>? onToken;
  final ValueChanged<String>? onError;
  final VoidCallback? onReady;

  const LiveSignView({
    super.key,
    required this.onWord,
    this.onToken,
    this.onError,
    this.onReady,
  });

  @override
  State<LiveSignView> createState() => _LiveSignViewState();
}

class _LiveSignViewState extends State<LiveSignView> {
  // Shared localhost server (serves the bundled asset over http://localhost so
  // the page is a secure context for the camera). Started once per process.
  static final InAppLocalhostServer _server = InAppLocalhostServer();
  static bool _started = false;

  Future<void>? _init;

  @override
  void initState() {
    super.initState();
    _init = _prepare();
  }

  Future<void> _prepare() async {
    await Permission.camera.request();
    if (!_started) {
      await _server.start();
      _started = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _init,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator(color: Colors.white)),
          );
        }
        return InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('http://localhost:8080/assets/sign/live_sign.html'),
          ),
          initialSettings: InAppWebViewSettings(
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            javaScriptEnabled: true,
            transparentBackground: true,
          ),
          onWebViewCreated: (controller) {
            controller.addJavaScriptHandler(
              handlerName: 'sign',
              callback: (args) {
                if (args.isEmpty) return;
                final m = args.first;
                if (m is! Map) return;
                final type = m['type']?.toString();
                final value = m['value'];
                switch (type) {
                  case 'word':
                    if (value is String && value.trim().isNotEmpty) widget.onWord(value);
                    break;
                  case 'token':
                    if (value is String) widget.onToken?.call(value);
                    break;
                  case 'ready':
                    widget.onReady?.call();
                    break;
                  case 'error':
                    widget.onError?.call(value?.toString() ?? 'Camera error');
                    break;
                }
                return null;
              },
            );
          },
          onPermissionRequest: (controller, request) async {
            // Grant the page the camera (OS runtime permission was requested above).
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          },
        );
      },
    );
  }
}
