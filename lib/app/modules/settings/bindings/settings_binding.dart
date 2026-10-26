import 'package:get/get.dart';

import '../controllers/settings_controller.dart';

/// 设置 tab binding。
class SettingsPageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<SettingsController>(() => SettingsController());
  }
}
