plugins {
    id("com.android.application")
    kotlin("android")
}
android {
    namespace = "dev.companion.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.companion.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-dev"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
