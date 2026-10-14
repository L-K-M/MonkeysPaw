plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
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
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)

    testImplementation(libs.kotlin.test)
}
