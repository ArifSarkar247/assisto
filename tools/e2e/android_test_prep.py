#!/usr/bin/env python3
"""e2eproof (Test Lab): make the generated Android project build an
instrumentation test APK that runs the integration_test flows on a real
device (Flutter's documented FlutterTestRunner setup). CI-only; run after
tools/reality/replay_android_steps.py. Touches only app/android (generated).
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "app" / "android" / "app"
JAVA = ROOT / "src/androidTest/java/com/assisto/assisto/MainActivityTest.java"
JAVA.parent.mkdir(parents=True, exist_ok=True)
JAVA.write_text("""package com.assisto.assisto;

import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import org.junit.Rule;
import org.junit.runner.RunWith;

@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
  @Rule
  public ActivityTestRule<MainActivity> rule = new ActivityTestRule<>(MainActivity.class, true, false);
}
""")
kts = ROOT / "build.gradle.kts"
groovy = ROOT / "build.gradle"
if kts.exists():
    s = kts.read_text()
    if "testInstrumentationRunner" not in s:
        s = s.replace("defaultConfig {", 'defaultConfig {\n        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"', 1)
    s += ('\ndependencies {\n    androidTestImplementation("androidx.test:runner:1.5.2")\n'
          '    androidTestImplementation("androidx.test:rules:1.5.0")\n'
          '    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")\n}\n')
    kts.write_text(s)
else:
    s = groovy.read_text()
    if "testInstrumentationRunner" not in s:
        s = s.replace("defaultConfig {", 'defaultConfig {\n        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"', 1)
    s += ("\ndependencies {\n    androidTestImplementation 'androidx.test:runner:1.5.2'\n"
          "    androidTestImplementation 'androidx.test:rules:1.5.0'\n"
          "    androidTestImplementation 'androidx.test.espresso:espresso-core:3.5.1'\n}\n")
    groovy.write_text(s)
print("androidTest ready:", JAVA)
