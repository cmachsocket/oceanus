plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cmach.oceanus"
    compileSdk = flutter.compileSdkVersion

    // 强制覆盖 Flutter SDK 写死的 ndkVersion=28.2.13676358,
    // 用系统里已有的 29.0.14206865(避免自动下载/无写权限)。

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.cmach.oceanus"
        // 继承 Flutter SDK 默认的 24 会让 manifest merger 拒绝合并。
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // native build 不在这里做——交给 packages/musiclibrary/ plugin 的
    // android/build.gradle.kts + CMakeLists.txt 处理,Flutter 工具链会自动
    // 把 plugin 生成的 .so 打包进 APK。

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."

}
