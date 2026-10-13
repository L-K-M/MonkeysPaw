pluginManagement {
    resolutionStrategy {
        eachPlugin {
            // Avoid the absent AGP marker JAR, whose CDN fallback times out.
            if (requested.id.id == "com.android.application") {
                useModule("com.android.tools.build:gradle:${requested.version}")
            }
        }
    }

    repositories {
        mavenCentral()
        google {
            // The implementation host needs Google's HTTP/1.1-capable CDN.
            providers.environmentVariable("MONKEYSPAW_GOOGLE_MAVEN_URL").orNull?.let { setUrl(it) }
        }
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
        google {
            providers.environmentVariable("MONKEYSPAW_GOOGLE_MAVEN_URL").orNull?.let { setUrl(it) }
        }
    }
}

rootProject.name = "MonkeysPaw"
include(":core", ":app")
