import 'package:get/get.dart';

import '../controllers/login_controller.dart';

/// 登录页 binding:跟 SearchPageBinding 同款
///
/// 由调用方在 Get.to(..., binding: LoginPageBinding()) 时按需注入
class LoginPageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<LoginController>(() => LoginController());
  }
}
