# Adapted from HalloMiao: enum names and generated serializers survive R8.
-keepclassmembers enum ch.lkmc.monkeyspaw.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# kotlinx.serialization entry points for the app and its shared JVM core.
-keepclassmembers class ch.lkmc.monkeyspaw.** {
    *** Companion;
}
-keepclasseswithmembers class ch.lkmc.monkeyspaw.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep the sync entry point while the M8 app skeleton has no sync caller, so
# release builds exercise ICU's reachable code and packaged data through R8.
-keep,allowoptimization class ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator {
    public *;
}
