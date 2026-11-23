# Keep gomobile / Go core JNI bindings intact
-keep class go.** { *; }
-keep class mobile.** { *; }
-dontwarn go.**
-dontwarn mobile.**

# Keep kotlinx.serialization generated serializers & models
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.whim.app.core.**$$serializer { *; }
-keepclassmembers class com.whim.app.core.** {
    *** Companion;
}
-keepclasseswithmembers class com.whim.app.core.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep WorkManager worker, receivers, widgets, and Quick Settings tile
-keep class com.whim.app.sync.SyncWorker { *; }
-keep class com.whim.app.review.DailyReviewReceiver { *; }
-keep class com.whim.app.capture.WhimWidgetProvider { *; }
-keep class com.whim.app.capture.WhimTileService { *; }
