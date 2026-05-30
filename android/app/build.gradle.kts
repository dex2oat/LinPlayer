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
                // Keep the JNI bridge self-contained so packaging does not
                // collide with the shared STL shipped by prebuilt native libs.
                arguments += "-DANDROID_STL=c++_static"
            }
        }

    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packagingOptions {
        // Prefer a single shared STL copy when prebuilt dependencies bundle it.
        pickFirsts += listOf(
            "lib/arm64-v8a/libc++_shared.so",
            "lib/armeabi-v7a/libc++_shared.so",
            "lib/x86/libc++_shared.so",
            "lib/x86_64/libc++_shared.so"
        )
        // 优先使用 jniLibs 中的 libmpv.so（支持 PGS 的版本）
        // 覆盖 media_kit 内置的 libmpv.so
        pickFirsts += listOf(
            "lib/arm64-v8a/libmpv.so",
            "lib/armeabi-v7a/libmpv.so",
            "lib/x86/libmpv.so",
            "lib/x86_64/libmpv.so"
        )
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
    val media3Version = "1.8.0"

    // Media3 ExoPlayer（原生播放器内核）
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-exoplayer-dash:$media3Version")

    // Mature ASS integration for Media3/ExoPlayer.
    implementation("io.github.peerless2012:ass-media:0.4.0")

    // FFmpeg 扩展（可选，当前仅作为 Media3 扩展库附加能力保留）
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
        println("   Some Media3 extension capabilities may be unavailable.")
        println("   Build with GitHub Actions to auto-compile, or see docs/FFmpegExtensionSetup.md")
    }
}

flutter {
    source = "../.."
}
