# Applied to every app that uses et_plate_reader (consumerProguardFiles).
# Release builds shrink and obfuscate with R8; without these the scanner
# fails only in release (2026-11-23: ML Kit's registrars lost their
# constructors and the camera view crashed on creation).

# ML Kit text recognition: components are found by reflection.
-keep class com.google.mlkit.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-dontwarn com.google.mlkit.**

# LiteRT / TensorFlow Lite (plate detector): native code calls into these.
-keep class org.tensorflow.lite.** { *; }
-keep class com.google.ai.edge.litert.** { *; }
-dontwarn org.tensorflow.lite.**

# The plugin itself (platform channel and view factory).
-keep class com.et_plate_reader.** { *; }
