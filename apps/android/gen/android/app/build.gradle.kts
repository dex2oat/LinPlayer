import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("rust")
}

val tauriProperties = Properties().apply {
    val propFile = file("tauri.properties")
    if (propFile.exists()) {
        propFile.inputStream().use { load(it) }
    }
}

/* ★★ 发布签名。**没有这一段,`tauri android build --apk` 出的是
   `app-universal-release-unsigned.apk` —— 一个 Android 直接拒装的包,
   用户看到的是「安装包无效 / 解析软件包时出现问题」,而 CI 全程绿灯。**

   坑在于:CI 那边把 keystore.properties 写好了、日志还打「有签名密钥 → 出 release APK」,
   看上去万事俱备 —— 但 Tauri 生成的这份 build.gradle.kts **默认根本不读那个文件**,
   release 变体连 signingConfig 都没有。写了配置文件 ≠ 用了配置文件。
   (2026-07-21 从 CI 产物实测:APK 里 META-INF 无 .RSA/.SF,也没有
    "APK Sig Block 42" 魔数 —— v1/v2/v3 三种签名一个都没有。)

   字段名必须和 .github/workflows/build.yml 的 "Write keystore" 步骤一字不差:
   storeFile / storePassword / keyAlias / password。 */
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile")?.isNotBlank() == true

android {
    compileSdk = 36
    namespace = "xyz.linplayer.tv"

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("password")
            }
        }
    }
    defaultConfig {
        manifestPlaceholders["usesCleartextTraffic"] = "false"
        /* ★ 设备上的身份用回旧安卓端的包名(删 Flutter 之前 android/app/build.gradle.kts
           里就是它)。换包名 = 变成另一个 App,老版本收不到覆盖升级。

           ⚠️ 只改 applicationId,**不要**顺手把 namespace / Kotlin 源码目录 /
           tauri.conf.json 的 identifier 也改成 xyz.linplayer.app。我 2026-07-21 试过,
           CI 当场炸在 `Unresolved reference: TauriActivity`:
             - identifier 决定 Tauri 找 app 的 src/main/java 下哪个包路径,
               改了就得连 Kotlin 源码目录一起搬;
             - 但那个包路径下的 generated 那批 kt(TauriActivity/Logger/Rust…)
               是 **wry 的 build script 产物**,且是 gitignore 的 —— CI 上 Rust
               命中缓存时(实测 0 个 crate 重编)build script 根本不跑,新路径下就是空的。
           applicationId 是 Gradle 层的,和源码包路径无关,单独改零风险 ——
           而 namespace 只是 R 类/MainActivity 的包名,用户看不见,改它收益为零。 */
        applicationId = "xyz.linplayer.app"
        minSdk = 24
        targetSdk = 36
        versionCode = tauriProperties.getProperty("tauri.android.versionCode", "1").toInt()
        versionName = tauriProperties.getProperty("tauri.android.versionName", "1.0")
    }
    buildTypes {
        getByName("debug") {
            manifestPlaceholders["usesCleartextTraffic"] = "true"
            isDebuggable = true
            isJniDebuggable = true
            isMinifyEnabled = false
            packaging {                jniLibs.keepDebugSymbols.add("*/arm64-v8a/*.so")
                jniLibs.keepDebugSymbols.add("*/armeabi-v7a/*.so")
                jniLibs.keepDebugSymbols.add("*/x86/*.so")
                jniLibs.keepDebugSymbols.add("*/x86_64/*.so")
            }
        }
        getByName("release") {
            /* 有正式密钥就用它;没有就**退回 debug 签名**。
               绝不允许再出现「未签名 release」—— 那种包用户装不上,
               而调试签名的包至少能装能测(只是不能覆盖安装正式版)。 */
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            proguardFiles(
                *fileTree(".") { include("**/*.pro") }
                    .plus(getDefaultProguardFile("proguard-android-optimize.txt"))
                    .toList().toTypedArray()
            )
        }
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
    buildFeatures {
        buildConfig = true
    }
}

rust {
    rootDirRel = "../../../"
}

dependencies {
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.lifecycle:lifecycle-process:2.10.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.4")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.0")
}

apply(from = "tauri.build.gradle.kts")