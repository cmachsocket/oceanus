import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:get/get.dart';

import '../sdk/netease_api.dart';
import 'audio_player_wrapper.dart';
import 'local_redirect_server.dart';
import 'lyrics_server_service.dart';
import 'tray_controller.dart';

/// 应用退出前按顺序释放原生资源。
///
/// **必须**在窗口真正销毁之前跑：关闭窗口时 Flutter engine 会直接拆掉 Dart
/// VM，而 media_kit 注册给 libmpv 的 wakeup 回调是 Dart NativeCallable。VM 一
/// 拆 trampoline 就失效，mpv 的工作线程仍会跳到那块内存 → SIGSEGV（退出码
/// 139，coredump 里表现为 libmpv 线程 `#0 n/a + 0x0`）。所以停播 + dispose
/// 播放器这一步不能省。node 子进程 / 两个本机 HTTP server / 托盘句柄同理。
///
/// 幂等：窗口 close 和托盘"退出"可能同时到达，重复调用返回同一个 future。
/// 每一步都是 best-effort —— 单步失败不能挡住后面的释放，更不能让窗口关不掉。
class AppShutdown {
  AppShutdown._();

  static Future<void>? _running;

  /// 兜底上限：任何一步卡死（比如 just_audio 的 stop 卡在原生调用上）都不能
  /// 让 setPreventClose(true) 之后的窗口关不掉。正常路径实测约 200ms。
  static const Duration _timeout = Duration(seconds: 5);

  /// 执行一次收尾。重复调用不会重复释放。
  static Future<void> run() => _running ??= _shutdown().timeout(
    _timeout,
    onTimeout: () =>
        debugPrint('[AppShutdown] 超过 ${_timeout.inSeconds}s 未完成，强制退出'),
  );

  static Future<void> _shutdown() async {
    // 1. 音频层最要紧：停播 → dispose just_audio → media_kit 清掉 mpv 的
    //    wakeup 回调并回收 NativeCallable。
    await _bestEffort('audio', () async {
      if (Get.isRegistered<AudioPlayerService>()) {
        await Get.find<AudioPlayerService>().shutdown();
      }
    });

    // 2. 内嵌 node bridge。桌面端是真实子进程，必须 await 它退出，
    //    否则 Flutter 先死、node 变孤儿。
    await _bestEffort('netease-api', () async {
      if (Get.isRegistered<NeteaseApi>()) {
        await Get.find<NeteaseApi>().shutdown();
      }
    });

    // 3. 两个本机 HTTP server（302 定向 / 歌词服务）。onClose 里会
    //    `close(force: true)` 掉监听 socket。
    await _bestEffort('redirect-server', () async {
      if (Get.isRegistered<LocalRedirectServer>()) {
        Get.delete<LocalRedirectServer>(force: true);
      }
    });
    await _bestEffort('lyrics-server', () async {
      if (Get.isRegistered<LyricsServerService>()) {
        Get.delete<LyricsServerService>(force: true);
      }
    });

    // 4. 托盘：dispose TrayIcon / Menu 并摘掉 WindowListener。
    await _bestEffort('tray', () async {
      if (Get.isRegistered<TrayController>()) {
        Get.delete<TrayController>(force: true);
      }
    });
  }

  static Future<void> _bestEffort(
    String name,
    Future<void> Function() step,
  ) async {
    try {
      await step();
    } catch (e, st) {
      debugPrint('[AppShutdown] $name 释放失败: $e\n$st');
    }
  }

  /// 仅测试用：清掉"已执行"标记，让下一个用例能重新跑一遍。
  @visibleForTesting
  static void resetForTest() => _running = null;
}
