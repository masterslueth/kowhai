# R8 / ProGuard rules for Kōwhai release builds.
#
# The release build type enables minification and resource shrinking so the
# shipped APK is not a readable copy of the app (see build.gradle.kts).
# `isMinifyEnabled` was previously false, so NONE of these rules had ever been
# exercised by a release build. Enabling R8 without them strips classes the
# plugins reach by reflection, which fails at RUNTIME, not at build time.

# ── Kotlin / annotation metadata ──────────────────────────────────────────────
-keepattributes *Annotation*, InnerClasses, EnclosingMethod, Signature
-keepattributes RuntimeVisibleAnnotations, RuntimeVisibleParameterAnnotations
-keepattributes AnnotationDefault

# ── Flutter embedding & plugins ──────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ── audio_service: notification, MediaBrowserService, custom actions ─────────
# Instantiated by name from the Android manifest and by platform-channel calls.
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audioservice.**$* { *; }
-keep class extends com.ryanheise.audioservice.AudioService { *; }
-keep class * extends androidx.media.session.MediaSession { *; }

# ── just_audio / ExoPlayer (Media3) ─────────────────────────────────────────
# Player extensions and extractors are loaded reflectively.
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**

# ── Google Cast (flutter_chrome_cast) ───────────────────────────────────────
-keep class com.google.android.gms.cast.** { *; }
-keep class com.google.android.gms.common.** { *; }
-keep class com.felnanuke.google_cast.** { *; }
-dontwarn com.google.android.gms.cast.**
-dontwarn com.google.android.gms.common.**

# ── Firebase ─────────────────────────────────────────────────────────────────
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**

# ── misc plugin reflection ───────────────────────────────────────────────────
-keep class androidx.lifecycle.** { *; }
-keep class com.ryanheise.** { *; }
-dontwarn javax.annotation.**
