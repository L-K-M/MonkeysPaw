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
