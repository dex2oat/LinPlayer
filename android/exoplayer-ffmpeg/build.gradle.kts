plugins {
    id("com.android.library")
}

android {
    namespace = "com.google.android.exoplayer2.ext.ffmpeg"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
        targetSdk = 34
        
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
                cppFlags += "-std=c++17"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/jni/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    implementation("androidx.media3:media3-common:1.8.0")
    implementation("androidx.media3:media3-decoder:1.8.0")
    implementation("androidx.media3:media3-exoplayer:1.8.0")
}
