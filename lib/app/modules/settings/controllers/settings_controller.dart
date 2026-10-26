import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

/// 播放音质等级。`.name` 与网易云 `/song/url/v1` 的 `level` 参数 1:1 映射,
/// **改名字会破坏已持久化的用户设置**,慎改。
enum Quality { standard, higher, exhigh, lossless, hires }

class SettingsController extends GetxController {
  static const _key = 'quality_v1';
  static const _exitToTrayKey = 'exit_to_tray_v1';
  final _box = GetStorage();

  late final Rx<Quality> currentQuality;
  final Rx<bool> downloadMode = false.obs;

  /// 关闭窗口时最小化到托盘,而不是退出应用。默认关(Linux/Windows 点 X 退出)。
  late final Rx<bool> exitToTray;

  @override
  void onInit() {
    super.onInit();
    // GetStorage.read 是同步的,不用 await。读不到 / 值不认识都回落到 standard。
    final saved = _box.read<String>(_key);
    currentQuality = Quality.values
        .firstWhere((e) => e.name == saved, orElse: () => Quality.standard)
        .obs;
    exitToTray = (_box.read<bool>(_exitToTrayKey) ?? false).obs;
  }

  /// 内存值先变再写盘,所以写盘失败也会保留新值(下次写盘重试)。
  /// 上层不需要 await。
  Future<void> setQuality(Quality q) async {
    currentQuality.value = q;
    await _box.write(_key, q.name);
  }

  /// 同 [setQuality]:先改内存再写盘,改完立刻生效(下次点关闭窗口时读取)。
  Future<void> setExitToTray(bool enabled) async {
    exitToTray.value = enabled;
    await _box.write(_exitToTrayKey, enabled);
  }
}
