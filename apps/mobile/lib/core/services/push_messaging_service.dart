import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:uuid/uuid.dart';

import '../network/api_client.dart';

/// Builds the native incoming-call (ringing) UI parameters for a push-delivered
/// call. Top-level so the background isolate can use it too.
CallKitParams incomingCallParams({
  required String fromUser,
  String? fromName,
  String? sessionId,
}) {
  final id =
      (sessionId != null && sessionId.isNotEmpty) ? sessionId : const Uuid().v4();
  return CallKitParams(
    id: id,
    nameCaller: (fromName != null && fromName.isNotEmpty) ? fromName : fromUser,
    appName: 'ConFriKa',
    handle: fromUser,
    type: 0,
    duration: 45000,
    textAccept: 'Answer',
    textDecline: 'Decline',
    extra: <String, dynamic>{
      'callerUsername': fromUser,
      if (sessionId != null) 'session_id': sessionId,
    },
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: true,
      ringtonePath: 'system_ringtone_default',
      backgroundColor: '#0D4C85',
      actionColor: '#288240',
      textColor: '#FFFFFF',
      incomingCallNotificationChannelName: 'ConFriKa In-App Voice Calls',
      missedCallNotificationChannelName: 'ConFriKa Missed Calls',
    ),
    ios: const IOSParams(
      iconName: 'CallKitIcon',
      handleType: 'generic',
      supportsVideo: false,
    ),
  );
}

/// Handles messages delivered while the app is in the background / terminated.
/// Must be a top-level (or static) function annotated for the VM entry point.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  final data = message.data;
  // Ring the phone (native CallKit UI) even when the app is closed. Call pushes
  // are sent data-only precisely so this handler runs.
  if (data['type'] == 'incoming_call') {
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(incomingCallParams(
        fromUser: data['from_user']?.toString() ?? '',
        fromName: data['from_name']?.toString(),
        sessionId: data['session_id']?.toString(),
      ));
    } catch (_) {/* best effort */}
  }
  // Message payloads carry a notification block, so the OS shows them in the
  // tray automatically — no work needed here.
}

/// Firebase Cloud Messaging integration: registers this device's push token so
/// the backend can alert the user to new messages and incoming calls even when
/// the app is closed.
class PushMessagingService {
  PushMessagingService._();
  static final PushMessagingService instance = PushMessagingService._();

  final _api = ConFriKaApiClient.instance;
  bool _inited = false;

  /// Callback invoked when a push indicates an incoming call (data payload with
  /// type == 'incoming_call'). Wired by the shell to open the call screen.
  void Function(String fromUsername, String? displayName)? onIncomingCall;

  Future<void> init() async {
    if (_inited) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);

      final fm = FirebaseMessaging.instance;
      await fm.requestPermission(alert: true, badge: true, sound: true);

      final token = await fm.getToken();
      if (token != null) {
        await _api.registerDevice(token);
      }
      fm.onTokenRefresh.listen(
        (t) => _api.registerDevice(t).catchError((_) {}),
      );

      // Foreground + tapped-notification routing.
      FirebaseMessaging.onMessage.listen(_route);
      FirebaseMessaging.onMessageOpenedApp.listen(_route);

      _inited = true;
    } catch (e) {
      debugPrint('Push init skipped: $e');
    }
  }

  void _route(RemoteMessage message) {
    final data = message.data;
    if (data['type'] == 'incoming_call') {
      onIncomingCall?.call(
        data['from_user']?.toString() ?? '',
        data['from_name']?.toString(),
      );
    }
  }
}
