import com.android.build.api.artifact.SingleArtifact
import groovy.json.JsonOutput
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.util.zip.ZipFile
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.api.tasks.testing.Test

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

@CacheableTask
abstract class GenerateSeedAssets : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val seedDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val source = seedDirectory.get().asFile.toPath()
        val paths = Files.walk(source).use { files ->
            files.filter { Files.isRegularFile(it, NOFOLLOW_LINKS) }.map { source.relativize(it).joinToString("/") }
                .filter { path ->
                    val parts = path.split('/')
                    path != "README.md" && path.endsWith(".md") && parts.none { it.startsWith('_') } &&
                        parts.dropLast(1).none { it.startsWith('.') }
                }.toList().sortedWith { a, b ->
                    // The Swift catalog sorts unsigned UTF-8, independent of locale or UTF-16.
                    val left = a.toByteArray(Charsets.UTF_8)
                    val right = b.toByteArray(Charsets.UTF_8)
                    var order = 0
                    for (index in 0 until minOf(left.size, right.size)) {
                        order = (left[index].toInt() and 255).compareTo(right[index].toInt() and 255)
                        if (order != 0) break
                    }
                    if (order == 0) left.size.compareTo(right.size) else order
                }
        }
        check(paths.isNotEmpty()) { "No eligible seed prompts found." }
        val output = outputDirectory.get().asFile
        check(!output.exists() || output.deleteRecursively()) { "Could not clear generated seed assets." }
        val seeds = output.resolve("seeds").apply { mkdirs() }
        for (path in paths) {
            val destination = seeds.resolve(path)
            destination.parentFile.mkdirs()
            Files.copy(source.resolve(path), destination.toPath())
        }
        seeds.resolve("catalog.json").writeText(
            JsonOutput.toJson(linkedMapOf("version" to 1, "paths" to paths)) + "\n", Charsets.UTF_8)
    }
}

/** Assembly gates check the actual APK, including release resource shrinking. */
abstract class VerifySeedApkAssets : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val generatedAssets: DirectoryProperty

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val apkDirectory: DirectoryProperty

    @TaskAction
    fun verify() {
        val root = generatedAssets.get().asFile.resolve("seeds")
        val expected = root.walkTopDown().filter { it.isFile }.associate { it.relativeTo(root).invariantSeparatorsPath to it.readBytes() }
        val apk = apkDirectory.get().asFile.listFiles { file -> file.extension == "apk" }?.singleOrNull()
            ?: error("Expected one assembled APK.")
        ZipFile(apk).use { zip ->
            val entries = zip.entries().asSequence().filter { !it.isDirectory && it.name.startsWith("assets/seeds/") }.toList()
            check(entries.map { it.name.removePrefix("assets/seeds/") }.sorted() == expected.keys.sorted()) {
                "APK seed membership differs from generated assets."
            }
            for (entry in entries) {
                check(zip.getInputStream(entry).use { it.readBytes() }.contentEquals(expected.getValue(entry.name.removePrefix("assets/seeds/")))) {
                    "APK seed bytes differ from generated assets."
                }
            }
        }
    }
}

val generateSeedAssets = tasks.register<GenerateSeedAssets>("generateSeedAssets") {
    seedDirectory.set(rootProject.layout.projectDirectory.dir("../seed"))
    outputDirectory.set(layout.buildDirectory.dir("generated/seedAssets"))
}

androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(generateSeedAssets, GenerateSeedAssets::outputDirectory)
    val name = variant.name.replaceFirstChar { it.uppercaseChar() }
    val verification = tasks.register<VerifySeedApkAssets>("verify${name}SeedAssets") {
        generatedAssets.set(generateSeedAssets.flatMap { it.outputDirectory })
        apkDirectory.set(layout.buildDirectory.dir("outputs/apk/${variant.name}"))
    }
    tasks.matching { it.name == "assemble$name" }.configureEach { finalizedBy(verification) }
    // The debug JVM gate also pins the release manifest that ships.
    val mergedManifest = variant.artifacts.get(SingleArtifact.MERGED_MANIFEST)
    tasks.withType<Test>().configureEach {
        systemProperty("monkeyspaw.mergedManifest.${variant.name}", mergedManifest.get().asFile.absolutePath)
        inputs.file(mergedManifest).withPropertyName("merged${variant.name}EntryManifest").withPathSensitivity(PathSensitivity.RELATIVE)
    }
}

android {
    namespace = "ch.lkmc.monkeyspaw"
    compileSdkVersion("android-37.0")

    defaultConfig {
        applicationId = "ch.lkmc.monkeyspaw"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "ch.lkmc.monkeyspaw.data.FileStoreInstrumentation"
    }

    // Packaging keeps the committed numeric version/code and injects the tag suffix.
    providers.gradleProperty("releaseVersion").orNull?.let { value ->
        val number = "(?:0|[1-9][0-9]*)"
        val identifier = "[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*"
        require(Regex("$number\\.$number\\.$number(?:-$identifier)?").matches(value)) {
            "releaseVersion must be X.Y.Z[-prerelease], without a v prefix or build metadata"
        }
        require(value.substringAfter('-', "").split('.').none {
            it.length > 1 && it.all { character -> character in '0'..'9' } && it.startsWith('0')
        }) { "releaseVersion numeric prerelease identifiers cannot have leading zeroes" }
        require(value.substringBefore('-') == defaultConfig.versionName) {
            "releaseVersion must agree with the committed numeric versionName"
        }
        defaultConfig.versionName = value
    }

    signingConfigs {
        // Public sideload signer for both variants; see docs/decisions/0001.
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.savedstate)
    implementation(libs.androidx.startup)
    implementation(libs.androidx.profileinstaller)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    ksp(libs.androidx.hilt.compiler)
    implementation(libs.androidx.hilt.work)
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.datastore)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.okhttp.coroutines)

    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.okhttp.tls)
}

val graphSources = layout.projectDirectory.dir("src/main")
// JVM integration tests inspect Core keyed stores; production uses service intents.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if (name.endsWith("UnitTestKotlin")) {
        compilerOptions.freeCompilerArgs.add(project(":core").layout.buildDirectory.file("libs/core.jar").map {
            "-Xfriend-paths=${it.asFile.absolutePath}"
        })
    }
}

tasks.withType<Test>().configureEach {
    dependsOn(generateSeedAssets)
    systemProperty("monkeyspaw.seedSources", generateSeedAssets.get().seedDirectory.get().asFile.absolutePath)
    systemProperty("monkeyspaw.seedAssets", generateSeedAssets.get().outputDirectory.get().asFile.absolutePath)
    inputs.dir(generateSeedAssets.flatMap { it.seedDirectory }).withPropertyName("seedSources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(generateSeedAssets.flatMap { it.outputDirectory }).withPropertyName("seedAssets").withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("monkeyspaw.appSources", graphSources.asFile.absolutePath)
    val coreSources = rootProject.layout.projectDirectory.dir("core/src/main/kotlin")
    systemProperty("monkeyspaw.coreSources", coreSources.asFile.absolutePath)
    inputs.dir(coreSources).withPropertyName("imeCoreSources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.files(graphSources.file("AndroidManifest.xml"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/di/AppModule.kt"),
        graphSources.file("res/xml/network_security_config.xml"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/MonkeysPawApplication.kt"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/MainActivity.kt"))
        .withPropertyName("appGraphSources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.files(graphSources.dir("kotlin/ch/lkmc/monkeyspaw/ui"), graphSources.file("res/values/strings.xml"),
        graphSources.file("res/values/editor_strings.xml"))
        .withPropertyName("libraryUiSources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.files(graphSources.file("kotlin/ch/lkmc/monkeyspaw/entry/FillActivity.kt"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/data/AndroidClipboard.kt"))
        .withPropertyName("fillBoundarySources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.files(graphSources.file("kotlin/ch/lkmc/monkeyspaw/data/LibraryRepository.kt"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/data/AndroidSyncStartup.kt"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/data/SyncWorkScheduler.kt"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/data/SyncWorker.kt"),
        graphSources.file("kotlin/ch/lkmc/monkeyspaw/ime/ImeInputPolicy.kt"))
        .withPropertyName("localSyncBoundarySources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.files(graphSources.dir("kotlin/ch/lkmc/monkeyspaw/entry"), graphSources.dir("res"))
        .withPropertyName("entrySources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(graphSources.dir("kotlin/ch/lkmc/monkeyspaw/ime"))
        .withPropertyName("imeSources").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(graphSources.dir("kotlin/ch/lkmc/monkeyspaw/data"))
        .withPropertyName("imeDriverSources").withPathSensitivity(PathSensitivity.RELATIVE)
}
