import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'settings_controller.dart';

/// SettingsPage 里的音质选择下拉框(选项与 [Quality] 枚举 1:1,顺序保持
/// 标准 → 较高 → 极高 → 无损 → Hi-Res)。`onChanged` 走 [SettingsController.set]
/// 同步写盘, 下一次 AudioPlayerHandler._playAt 自动读到新 quality。
///
/// 用户改了 quality 不会自动重新拉当前歌的 URL —— 下一首 / 自然播完触发
/// _playAt 时才用新 level。如果想"立刻生效", 需要上层 UI 调 wrapper 的
/// reloadCurrent() (本类不管, 范围外)。
class QualitySwitcher extends StatelessWidget {
  const QualitySwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsCtrl = Get.find<SettingsController>();
    return Obx(
      () => DropdownButton<Quality>(
        value: settingsCtrl.currentQuality.value,
        items: const [
          DropdownMenuItem(value: Quality.standard, child: Text('标准')),
          DropdownMenuItem(value: Quality.higher, child: Text('较高')),
          DropdownMenuItem(value: Quality.exhigh, child: Text('极高')),
          DropdownMenuItem(value: Quality.lossless, child: Text('无损')),
          DropdownMenuItem(value: Quality.hires, child: Text('Hi-Res')),
        ],
        onChanged: (value) {
          if (value != null) {
            settingsCtrl.setQuality(value);
          }
        },
      ),
    );
  }
}
