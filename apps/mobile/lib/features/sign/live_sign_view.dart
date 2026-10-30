import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/network/api_client.dart';

/// Live-camera sign recognition for mobile.
///
/// Runs MediaPipe inside an in-app WebView served over the WebView's localhost
/// server (a secure context, which `getUserMedia` requires). Two modes:
///   • `spell` — MediaPipe Hands + the geometric fingerspelling recognizer,
///     entirely on-device; finished words are posted straight to Flutter.
///   • `words` — MediaPipe Holistic (face + pose + both hands). A whole sign's
///     landmark burst is posted to Flutter, which calls the backend's trained
///     250-sign model and pushes the recognized word back into the page.
class LiveSignView extends StatefulWidget {
  final ValueChanged<String> onWord;
  final ValueChanged<String>? onToken;
  final ValueChanged<String>? onError;
  final VoidCallback? onReady;

  /// 'spell' (fingerspelling) or 'words' (trained whole-word model).
  final String mode;

  const LiveSignView({
    super.key,
    required this.onWord,
    this.onToken,
    this.onError,
    this.onReady,
    this.mode = 'spell',
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
  InAppWebViewController? _controller;

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

  WebUri get _url => WebUri(
      'http://localhost:8080/assets/sign/live_sign.html?mode=${widget.mode}');

  @override
  void didUpdateWidget(covariant LiveSignView old) {
    super.didUpdateWidget(old);
    // Switching mode needs a different MediaPipe model → reload the page.
    if (old.mode != widget.mode) {
      _controller?.loadUrl(urlRequest: URLRequest(url: _url));
    }
  }

  Future<void> _onFrames(dynamic value) async {
    if (value is! String || value.isEmpty) return;
    List<Map<String, dynamic>> frames;
    try {
      final decoded = jsonDecode(value) as List;
      frames = decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return;
    }
    if (frames.isEmpty) return;
    try {
      final out = await ConFriKaApiClient.instance.recognizeSignWord(frames: frames);
      final label = (out['label'] ?? '').toString();
      final token = (out['token'])?.toString();
      final conf = (out['confidence'] is num) ? (out['confidence'] as num).toDouble() : 0.0;
      final note = (out['note'] ?? '').toString();
      // Speak when reasonably confident; otherwise surface the best guess only.
      const speakMin = 0.35;
      final accept = token != null && token.isNotEmpty && conf >= speakMin;
      await _controller?.evaluateJavascript(source:
          'window.cfResult && window.cfResult(${jsonEncode(label)}, $accept, ${jsonEncode(note)});');
      if (accept) {
        widget.onWord(label.isNotEmpty ? label : token);
      } else {
        widget.onToken?.call(note.isNotEmpty ? note : 'Not sure — sign bigger, centered.');
      }
    } catch (e) {
      await _controller?.evaluateJavascript(source:
          'window.cfResult && window.cfResult("", false, ${jsonEncode('Could not reach the recognizer.')});');
      widget.onError?.call('Could not reach the sign recognizer.');
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
          initialUrlRequest: URLRequest(url: _url),
          initialSettings: InAppWebViewSettings(
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            javaScriptEnabled: true,
            transparentBackground: true,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
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
                  case 'frames':
                    _onFrames(value);
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
