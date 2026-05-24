plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.linplayer_mobile"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.linplayer_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += "-DANDROID_STL=c++_shared"
            }
        }

    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // Media3 ExoPlayer（原生播放器内核）
    implementation("androidx.media3:media3-exoplayer:1.3.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.3.1")
    implementation("androidx.media3:media3-exoplayer-dash:1.3.1")

    // FFmpeg 扩展（可选，用于 PGS/SUP 图形字幕支持）
    // GitHub Actions 会自动编译并放置到此路径
    val ffmpegAar = file("../exoplayer-ffmpeg/libs/ffmpeg-extension.aar")
    if (ffmpegAar.exists()) {
        implementation(files(ffmpegAar))
        println("✅ FFmpeg extension found: ${ffmpegAar.absolutePath}")
    } else {
        println("⚠️ FFmpeg extension not found. PGS/SUP subtitle support disabled.")
        println("   Build with GitHub Actions to auto-compile, or see docs/FFmpegExtensionSetup.md")
    }
}

flutter {
    source = "../.."
}
