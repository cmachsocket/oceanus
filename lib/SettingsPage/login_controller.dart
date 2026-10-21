import 'dart:async';
import '../models/default.dart';

import 'package:flutter/widgets.dart' show TextEditingController;
import 'package:get/get.dart';
import '../sdk/auth_controller.dart';

/// 登录页 controller(手机 + 验证码):UI 状态 + 业务编排(输入验证 / 倒计时 /
/// snackbar)。
///
/// - 输入框数据源统一走 [phoneController] / [codeController] + listener 同步到 RxString,
///   理由同 [SearchController.textController]:不显式绑 controller 的话清除/回填 TextField
///   没反应(因为 Flutter 复用 TextField 内部看不见的 TextEditingController state)
/// - **凭证管理**:SDK 调用(`/captcha/sent` / `/login/cellphone` / cookie 持久化)
///   全部在 [AuthController],本 controller 不直接碰 SDK
class LoginController extends GetxController {
  static const int phoneLength = 11;

  /// 验证码输入框**上限**(防呆:避免用户输 100 位)。
  ///
  /// **不假设验证码位数** —— 网易云后端会动态调整(见过 4/6/8 位),
  /// 所以**只设上限不限下限**,位数交给后端决定。
  static const int codeMaxLength = 8;
  static const int countdownSeconds = 60;
  static const String countryCode = '86';
  static const Duration tickInterval = Duration(seconds: 1);

  // 中国大陆手机号 + 任意位数字验证码 (只验"非空 + 全数字",不验位数)
  static final RegExp _phonePattern = RegExp(r'^1\d{10}$');
  static final RegExp _codePattern = RegExp(r'^\d+$');

  final TextEditingController phoneController = TextEditingController();
  final TextEditingController codeController = TextEditingController();

  final RxString phone = ''.obs;
  final RxString code = ''.obs;

  /// 倒计时剩余秒数;>0 表示冷却中
  final RxInt countdown = 0.obs;

  /// 发送验证码 / 登录请求进行中(用于 UI loading)
  final RxBool isSendingCode = false.obs;
  final RxBool isLoggingIn = false.obs;

  Timer? _timer;

  /// 全局凭证持有者 —— 真正的 SDK 调用都走它。
  /// `permanent: true` 全局 controller, 启动时 main.dart 注册。
  late final AuthController _auth;

  @override
  void onInit() {
    super.onInit();
    _auth = Get.find<AuthController>();

    phoneController.addListener(_syncPhone);
    codeController.addListener(_syncCode);
  }

  @override
  void onClose() {
    phoneController.removeListener(_syncPhone);
    phoneController.dispose();
    codeController.removeListener(_syncCode);
    codeController.dispose();
    _timer?.cancel();
    super.onClose();
  }

  void _syncPhone() => phone.value = phoneController.text;
  void _syncCode() => code.value = codeController.text;

  bool get isPhoneValid => _phonePattern.hasMatch(phone.value);

  /// 验证码格式合法:非空 + 全数字(**不限位数**,后端动态决定)
  bool get isCodeValid => _codePattern.hasMatch(code.value);

  bool get canSendCode =>
      isPhoneValid && countdown.value == 0 && !isSendingCode.value;

  bool get canLogin => isPhoneValid && isCodeValid && !isLoggingIn.value;

  void _startCountdown() {
    countdown.value = countdownSeconds;
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) {
      countdown.value--;
      if (countdown.value <= 0) {
        _timer?.cancel();
      }
    });
  }

  /// 发送验证码 —— 委托给 [AuthController.sendCode]。
  /// 成功 → 启动 60s 倒计时(期间按钮置灰);失败 → SnackBar。
  void sendCode() async {
    if (!canSendCode) return;
    isSendingCode.value = true;
    try {
      final ok = await _auth.sendCode(
        phoneStr: phone.value,
        countryCode: countryCode,
      );
      if (ok) {
        _startCountdown();
      } else {
        Get.snackbar('发送失败', '请稍后重试', snackPosition: SnackPosition.BOTTOM);
      }
    } finally {
      isSendingCode.value = false;
    }
  }

  /// 登录 —— 委托给 [AuthController.login]
  ///
  /// 成功 → 先 [Get.back] 退回 Settings, 再弹"登录成功" SnackBar
  /// (顺序重要,见下方实现处的说明);失败 → SnackBar 提示
  /// (常见: 验证码错 / 风控要求扫码 / 频繁登录)
  void login() async {
    if (!canLogin) return;
    isLoggingIn.value = true;
    try {
      final ok = await _auth.login(
        phoneStr: phone.value,
        codeStr: code.value,
        countryCode: countryCode,
      );
      if (ok) {
        Get.back(id: DefaultValues.shellNavigatorId);
        // snackbar 在 back 之后调, 挂在 Settings 的 overlay 上,
        // 不会被 back 的 route dispose 一起干掉
        Get.snackbar(
          '登录成功',
          '已保存登录状态, 下次启动自动恢复',
          snackPosition: SnackPosition.BOTTOM,
        );
      } else {
        Get.snackbar(
          '登录失败',
          '请检查手机号 / 验证码 (常见: 验证码错 / 风控要求扫码 / 频繁登录)',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } finally {
      isLoggingIn.value = false;
    }
  }

  /// 退出登录 —— 委托给 [AuthController.logout](内部清 SDK cookie + GetStorage + 持久化)
  Future<bool> logout() => _auth.logout();
}

/// 后面要全部重构snackbar提示，移动到view层，controller只负责业务逻辑。
