import 'package:get/get.dart';

class AppShellController extends GetxController {
  final RxInt index = 0.obs;
  void change(int i) => index.value = i;
}

class AppShellBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<AppShellController>(() => AppShellController());
    // PlayerController 在 main.dart 里 `Get.put(..., permanent: true)` 已经
    // 注册,跨 tab 路由活。这里不重复 lazyPut,避免 GetX 内部 find 已有后又
    // 创建的浪费。
  }
}
