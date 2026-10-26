import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../../core/constants/default_values.dart';
import '../controllers/login_controller.dart';

/// 登录页(手机 + 验证码)
///
/// - 入口:调用方 `Get.to(() => LoginPage(), binding: LoginPageBinding())`
/// - 接 SDK:[LoginController.sendCode] 调 `/captcha/sent`;失败弹 SnackBar
///   [LoginController.login] 调 `/login/cellphone`;成功后 Get.back() + 持久化 cookie
/// - 数据源:[LoginController.phoneController] / [codeController] 显式绑给 TextField,
///   清除/回填才能真正生效(跟 SearchController 同款)
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LoginController>();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(id: DefaultValues.shellNavigatorId),
        ),
        title: const Text('登录'),
      ),
      body: ListView(
        children: [
          // 手机号输入框
          TextField(
            controller: controller.phoneController,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(LoginController.phoneLength),
            ],
            decoration: const InputDecoration(
              labelText: '手机号',
              hintText: '请输入 ${LoginController.phoneLength} 位手机号',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),

          // 验证码输入框
          // - 只设上限 (codeMaxLength) 防呆,不限制下限/位数:
          //   网易云后端会动态改验证码位数 (4/6/8 都见过),前端不知该信哪个,
          //   猜错了用户输不进去 → 反正 SDK 返错时能拿到 [ApiException.message] 提示。
          TextField(
            controller: controller.codeController,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(LoginController.codeMaxLength),
            ],
            decoration: const InputDecoration(
              labelText: '验证码',
              hintText: '请输入验证码',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),

          // "获取验证码" 按钮:放在右下角当链接式按钮,loading 时显示 spinner
          Obx(
            () => Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: controller.canSendCode ? controller.sendCode : null,
                child: controller.isSendingCode.value
                    ? const CircularProgressIndicator()
                    : Text(_sendCodeLabel(controller.countdown.value)),
              ),
            ),
          ),

          // 登录按钮:全宽 ElevatedButton,跟项目其他页面一致
          Obx(
            () => ElevatedButton(
              onPressed: controller.canLogin ? controller.login : null,
              child: controller.isLoggingIn.value
                  ? const CircularProgressIndicator()
                  : const Text('登录'),
            ),
          ),
        ],
      ),
    );
  }

  /// 倒计时文案:冷却中显示 "重新发送(59s)",否则显示 "获取验证码"
  static String _sendCodeLabel(int countdown) =>
      countdown > 0 ? '重新发送(${countdown}s)' : '获取验证码';
}
