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
