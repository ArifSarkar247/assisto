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
