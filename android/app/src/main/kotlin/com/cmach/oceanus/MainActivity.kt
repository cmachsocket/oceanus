package com.cmach.oceanus

import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

/// 主 Activity (audio_service 集成)
///
/// - **继承 `AudioServiceActivity`** 而不是 `FlutterActivity`:
///   audio_service 需要共享 FlutterEngine 给前台服务, AudioServiceActivity 提供
///   `provideFlutterEngine` / `getCachedEngineId` / `shouldDestroyEngineWithHost`
///   这三个方法的默认实现, 让 audio_service 能在后台启动时复用 engine.
/// - **保留 `window.setDecorFitsSystemWindows(true)`**: 关掉 Android 15+ (API 35) 默认
///   edge-to-edge 强制, 状态栏/导航栏保留系统自己位置, Flutter UI 在它们下方绘制
///   (传统 Android 风格, 用户的明确需求).
/// - 没这个 API 的 Android < 11 设备走 framework deprecated path, 不影响.
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 关掉 edge-to-edge, 状态栏/导航栏保留系统自己位置
        window.setDecorFitsSystemWindows(true)
    }
}