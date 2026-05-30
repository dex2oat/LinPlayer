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

    packagingOptions {
        jniLibs {
            // 使用 jniLibs 中的 libmpv.so（包含 PGS 解码器和 libass）
            // 覆盖 media_kit 自动下载的旧版本
            pickFirsts += setOf("**/libmpv.so")
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
    // 支持多种文件名格式（不同版本的 ExoPlayer 生成的文件名不同）
    val possibleAarNames = listOf(
        "ffmpeg-extension.aar",
        "lib-decoder-ffmpeg-release.aar",
        "decoder_ffmpeg-release.aar"
    )
    var ffmpegAar: java.io.File? = null
    for (aarName in possibleAarNames) {
        val candidate = file("../exoplayer-ffmpeg/libs/$aarName")
        if (candidate.exists()) {
            ffmpegAar = candidate
            break
        }
    }
    if (ffmpegAar != null) {
        implementation(files(ffmpegAar))
        println("✅ FFmpeg extension found: ${ffmpegAar.absolutePath}")
    } else {
        println("⚠️ FFmpeg extension not found at: ${file("../exoplayer-ffmpeg/libs/").absolutePath}")
        println("   Expected one of: ${possibleAarNames.joinToString()}")
        println("   PGS/SUP subtitle support will be limited.")
        println("   Build with GitHub Actions to auto-compile, or see docs/FFmpegExtensionSetup.md")
    }
}

flutter {
    source = "../.."
}
