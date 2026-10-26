import 'package:get/get.dart';

import '../controllers/home_controller.dart';

/// 发现页绑定。
class HomePageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(() => HomeController());
  }
}
