import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.testing.Test

plugins {
    alias(libs.plugins.kotlin.jvm)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.icu4j)
    implementation(libs.snakeyaml.engine)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
}

val fixtureDirectory = rootProject.layout.projectDirectory.dir("../spec/fixtures")
val schemaDirectory = rootProject.layout.projectDirectory.dir("../spec/schema")
val syncFoldReference = rootProject.layout.projectDirectory.file("../Sources/MonkeysPawCore/Sync/SyncPathCaseFold.swift")
val assistantPromptDirectory = rootProject.layout.projectDirectory.dir("../Assistant/Prompts")

val syncIntegrationTest = sourceSets.create("syncIntegrationTest")
kotlin.target.compilations.named(syncIntegrationTest.name) {
    associateWith(kotlin.target.compilations.getByName("main"))
}
val sharedHttpSource = rootProject.layout.projectDirectory.file(
    "app/src/main/kotlin/ch/lkmc/monkeyspaw/data/OkHttpHttpTransport.kt",
)
kotlin.sourceSets.named(syncIntegrationTest.name) {
    kotlin.srcDir(rootProject.layout.projectDirectory.dir("app/src/main/kotlin"))
    kotlin.include("ch/lkmc/monkeyspaw/core/integration/**", "ch/lkmc/monkeyspaw/data/OkHttpHttpTransport.kt",
        "ch/lkmc/monkeyspaw/data/RootedFileStore.kt")
}
configurations[syncIntegrationTest.implementationConfigurationName]
    .extendsFrom(configurations.testImplementation.get())
configurations[syncIntegrationTest.runtimeOnlyConfigurationName]
    .extendsFrom(configurations.testRuntimeOnly.get())
dependencies {
    add(syncIntegrationTest.implementationConfigurationName, libs.okhttp)
    add(syncIntegrationTest.implementationConfigurationName, libs.okhttp.coroutines)
}

tasks.register<Test>(syncIntegrationTest.name) {
    description = "Check sync scenario infrastructure and the optional local live smoke (Z15 partial proof)."
    group = "verification"
    testClassesDirs = syncIntegrationTest.output.classesDirs
    classpath = syncIntegrationTest.runtimeClasspath
    inputs.file(sharedHttpSource).withPropertyName("sharedHttpTransport")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.file(rootProject.layout.projectDirectory.file("app/src/main/kotlin/ch/lkmc/monkeyspaw/data/RootedFileStore.kt"))
        .withPropertyName("sharedRootedFiles").withPathSensitivity(PathSensitivity.RELATIVE)
    // A previous success cannot replace a real server run.
    outputs.upToDateWhen { false }
    outputs.cacheIf { false }
    environment("MONKEYSPAW_SYNC_MANIFEST", providers.environmentVariable("MONKEYSPAW_SYNC_MANIFEST").orElse("").get())
    environment("MONKEYSPAW_REQUIRE_SYNC_SERVER", providers.environmentVariable("MONKEYSPAW_REQUIRE_SYNC_SERVER").orElse("").get())
    testLogging {
        events("failed", "skipped")
        showStandardStreams = true
    }
}

tasks.withType<Test>().configureEach {
    systemProperty("monkeyspaw.fixtures", fixtureDirectory.asFile.absolutePath)
    systemProperty("monkeyspaw.schema", schemaDirectory.asFile.absolutePath)
    systemProperty("monkeyspaw.syncFoldReference", syncFoldReference.asFile.absolutePath)
    systemProperty("monkeyspaw.assistantPrompts", assistantPromptDirectory.asFile.absolutePath)
    inputs.dir(fixtureDirectory).withPropertyName("promptFixtures")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(schemaDirectory).withPropertyName("syncSchemas")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.file(syncFoldReference).withPropertyName("syncFoldReference")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(assistantPromptDirectory).withPropertyName("assistantPrompts")
        .withPathSensitivity(PathSensitivity.RELATIVE)
}
