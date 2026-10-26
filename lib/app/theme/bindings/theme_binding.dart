import 'package:get/get.dart';

import '../controllers/theme_controller.dart';

/// 主题绑定。
class ThemeBinding extends Bindings {
  @override
  void dependencies() => Get.lazyPut(() => ThemeController());
}
