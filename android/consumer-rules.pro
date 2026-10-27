# ML Kit finds its components (the text recognizer among them) by reflection;
# R8 in full mode strips them and TextRecognition.getClient then fails with a
# NullPointerException in release builds.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.mlkit.common.internal.MlKitComponentDiscoveryService
