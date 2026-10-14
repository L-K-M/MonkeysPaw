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

tasks.withType<Test>().configureEach {
    systemProperty("monkeyspaw.fixtures", fixtureDirectory.asFile.absolutePath)
    systemProperty("monkeyspaw.schema", schemaDirectory.asFile.absolutePath)
    systemProperty("monkeyspaw.syncFoldReference", syncFoldReference.asFile.absolutePath)
    inputs.dir(fixtureDirectory).withPropertyName("promptFixtures")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(schemaDirectory).withPropertyName("syncSchemas")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.file(syncFoldReference).withPropertyName("syncFoldReference")
        .withPathSensitivity(PathSensitivity.RELATIVE)
}
