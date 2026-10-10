import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

/// 播放音质等级。`.name` 与网易云 `/song/url/v1` 的 `level` 参数 1:1 映射,
/// **改名字会破坏已持久化的用户设置**,慎改。
enum Quality { standard, higher, exhigh, lossless, hires }

class SettingsController extends GetxController {
  static const _key = 'quality_v1';
  final _box = GetStorage();

  late final Rx<Quality> currentQuality;
  final Rx<bool> downloadMode = false.obs;

  @override
  void onInit() {
    super.onInit();
    // GetStorage.read 是同步的,不用 await。读不到 / 值不认识都回落到 standard。
    final saved = _box.read<String>(_key);
    currentQuality = Quality.values
        .firstWhere((e) => e.name == saved, orElse: () => Quality.standard)
        .obs;
  }

  /// 内存值先变再写盘,所以写盘失败也会保留新值(下次写盘重试)。
  /// 上层不需要 await。
  Future<void> setQuality(Quality q) async {
    currentQuality.value = q;
    await _box.write(_key, q.name);
  }
}
