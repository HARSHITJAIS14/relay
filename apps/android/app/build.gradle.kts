import java.util.Properties

plugins {
    id("com.android.application")
    kotlin("android")
}
val releaseSigningFile = rootProject.file("../../.tooling/android-signing/release.properties")
val releaseSigningProperties = Properties().apply {
    if (releaseSigningFile.exists()) releaseSigningFile.inputStream().use { load(it) }
}

android {
    namespace = "dev.companion.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.companion.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 10
        versionName = "1.6.4"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        if (releaseSigningFile.exists()) {
            create("relayRelease") {
                storeFile = releaseSigningFile.parentFile.resolve(releaseSigningProperties.getProperty("storeFile"))
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        getByName("release") {
            isDebuggable = false
            if (releaseSigningFile.exists()) signingConfig = signingConfigs.getByName("relayRelease")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("androidTest").assets.srcDirs(
        "../../../protocol/fixtures", "build/generated/probeAssets"
    )
}
kotlin { jvmToolchain(17) }
dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

// Fail release packaging rather than silently distribute an unsigned APK.
tasks.configureEach {
    if (name == "validateSigningRelease" || name == "packageRelease" || name == "signReleaseBundle") {
        doFirst {
            check(releaseSigningFile.exists()) {
                "Release key missing. Run python3 tools/setup_android_signing.py and securely back it up."
            }
        }
    }
}
