# Assisto release (R8) keep rules. Copied over the generated android/app/ by
# the CI overlay step; Flutter's Gradle plugin applies app/proguard-rules.pro.
#
# Builds 147-150 (release only): SharedPreferences failed on every launch with
#   NoSuchMethodError: SharedPreferencesApiRegistrar.getAll(String, List, Continuation)
# -> settings, theme, language and Phone Safety state could not be read/saved.
# The plugin's Pigeon classes are looked up by name, so R8 must keep them.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class androidx.datastore.** { *; }
-keepclassmembers class * extends androidx.datastore.preferences.protobuf.GeneratedMessageLite { <fields>; }

# The plugin's JNI registrars (SharedPreferencesApiRegistrar etc.) are found by
# EXACT JNI signature, e.g. getAll(String, List, kotlin.coroutines.Continuation).
# Keeping the class was not enough: R8 renamed kotlin.coroutines.Continuation
# (to "t70" in build 151's smoke APK), so the lookup still failed. Keep the
# NAMES of the Kotlin types that appear in JNI signatures, and the JNI runtime.
-keep class kotlin.coroutines.Continuation
-keepnames class kotlin.coroutines.**
-keepnames class kotlin.jvm.functions.**
-keep class kotlin.Unit
-keep class com.github.dart_lang.jni.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }

# Every JVM class the compiled Dart (libapp.so) looks up through JNI, taken from
# the strings of build 152's x64 release libapp.so. java.* are never renamed;
# these must survive R8 with their names and members (build 152 failed next on
# ClassNotFoundException kotlin/Result once Continuation was fixed).
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.ResultKt { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }

# ---- p2-photo ---- Photo Studio on-device AI (ONNX Runtime upscaler): the JNI
# library creates / reads ai.onnxruntime Java objects by name and the AAR ships
# no consumer rules (same rule as k1-wake; a duplicate -keep is harmless).
-keep class ai.onnxruntime.** { *; }

# ---- sc1 ---- Crashlytics: readable JVM stack traces (Firebase docs). The SDK
# and the firebase_crashlytics plugin ship their own consumer rules; these only
# keep file/line info and exception class names (mapping upload is off).
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# ---- r8-notif (Play Vitals 26 Oct) ---- flutter_local_notifications stores
# scheduled notifications as JSON via Gson and rebuilds them in
# ScheduledNotificationBootReceiver (BOOT_COMPLETED / MY_PACKAGE_REPLACED, i.e.
# after every reboot AND every app update). R8 stripped the generic signature of
# its Gson TypeToken -> "IllegalStateException: TypeToken must be created with a
# type argument" crashed the receiver (realme Note 70 / Android 16, realme 9i /
# Android 13; builds 10221-10224) and scheduled reminders were NOT restored.
# Rules from the plugin's README + Gson's R8 guidance.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.dexterous.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
