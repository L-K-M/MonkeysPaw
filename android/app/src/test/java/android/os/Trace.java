package android.os;

/** Compose state tests run without Android tracing on the local JVM. */
public final class Trace {
    private Trace() {}

    public static void beginSection(String sectionName) {}
    public static void endSection() {}
}
