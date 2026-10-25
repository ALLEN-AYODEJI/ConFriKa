# ConFriKa R8/ProGuard keep rules.
# Flutter and most plugins ship their own consumer rules; these are extra
# safety keeps for native-interop libraries used by the app.

# App entry point + own classes (MainActivity is referenced only from the
# manifest, so R8 strips it without this and the app fails to launch).
-keep class com.confrika.confrika_mobile.** { *; }

# Flutter
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# flutter_callkit_incoming (manifest-referenced activity/receivers)
-keep class com.hiennv.flutter_callkit_incoming.** { *; }
-dontwarn com.hiennv.flutter_callkit_incoming.**

# WebRTC (flutter_webrtc) — native method bridges
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Google Mobile Ads
-keep class com.google.android.gms.ads.** { *; }
-dontwarn com.google.android.gms.ads.**

# Google Play Billing (in_app_purchase)
-keep class com.android.billingclient.** { *; }
-dontwarn com.android.billingclient.**

# Firebase Cloud Messaging
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Keep annotations and generic signatures (reflection-based serializers)
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
