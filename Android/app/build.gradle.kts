plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.a2m.audiorepeater"
    compileSdk {
        version = release(36)
    }

    defaultConfig {
        applicationId = "com.a2m.audiorepeater"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    buildFeatures {
        compose = true
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

val pixel10MmapAssets = layout.buildDirectory.dir("generated/pixel10MmapAssets")
val pixel10MmapPlayer = pixel10MmapAssets.map { it.file("pixel10_mmap/arm64-v8a/player") }
android.sourceSets.getByName("main").assets.srcDir(pixel10MmapAssets)
val buildPixel10MmapHelper by tasks.registering(Exec::class) {
    val source = file("src/main/cpp/pixel10_mmap/pcm_mmap_player.c")
    val header = file("src/main/cpp/pixel10_mmap/tinyalsa_abi.h")
    inputs.files(source, header)
    outputs.file(pixel10MmapPlayer)
    doFirst {
        val ndk = androidComponents.sdkComponents.ndkDirectory.get().asFile
        val os = System.getProperty("os.name").lowercase()
        val host = if (os.contains("windows")) "windows-x86_64" else if (os.contains("mac")) "darwin-x86_64" else "linux-x86_64"
        val compiler = ndk.resolve("toolchains/llvm/prebuilt/$host/bin/clang" + if (os.contains("windows")) ".exe" else "")
        val output = pixel10MmapPlayer.get().asFile
        output.parentFile.mkdirs()
        commandLine(compiler.absolutePath, "--target=aarch64-linux-android28", "-O2", "-fPIE", "-pie",
            "-Wl,-z,max-page-size=16384", source.absolutePath, "-ldl", "-o", output.absolutePath)
    }
}
tasks.configureEach { if (name == "preBuild") dependsOn(buildPixel10MmapHelper) }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
