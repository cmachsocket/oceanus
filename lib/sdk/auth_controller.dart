/// 登录凭证的全局持有者
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get.dart';
import '../app/data/models/auth_info.dart';
import 'netease_api.dart';

class AuthController extends GetxController {
  final Rx<AuthInfo> authInfo = AuthInfo.empty().obs;
  bool get loggedIn => authInfo.value.loggedIn;
  int get currentUid => authInfo.value.currentUid;
  final NeteaseApi _auth = Get.find<NeteaseApi>();

  Future<bool> sendCode({
    required String phoneStr,
    required String countryCode,
  }) async {
    try {
      // 匿名访客 cookie (NMTID/NMSCVT) 由 NeteaseApi.init 启动时一次性拉,这里
      // 不再调 applyAnonymousCookie 避免重复请求。
      await _auth.sendCaptcha(phone: phoneStr, ctcode: countryCode);
      return true;
    } catch (_) {
      // 非 ApiException (PlatformException / 网络栈异常) 也兜底,否则会沿
      // LoginController 冒泡,UI 连 snackbar 都看不到
      return false;
    }
  }

  /// 1. 先建访客 session(拿 NMTID/NMSCVT),让后端把这次请求当成"已有会话的
  ///    设备",避开裸 IP 直连触发云盾 10004 + phoneReuse 重定向。第 1 步失败不
  ///    阻断第 2 步,最坏就是被云盾挡。
  /// 2. 发登录请求(验证码分支)。
  /// 3. 成功判定 = **cookie 非空**(见下),不是响应 code。
  Future<bool> login({
    required String phoneStr,
    required String codeStr,
    required String countryCode,
  }) async {
    try {
      await _auth.applyAnonymousCookie();
      final r = await _auth.loginCellphone(
        phone: phoneStr,
        captcha: codeStr,
        countrycode: countryCode,
      );
      final cookies = await _auth.applyLoginCookie(r);
      // 没拿到身份 cookie = 登录失败:多半是云盾拦截 / 风控重定向,
      // 业务 code 200 但 cookie 缺失。uid 拿不到不算失败。
      if (cookies.isEmpty) {
        authInfo.value = AuthInfo.empty();
        return false;
      }
      await loadAuthInfo();
      return authInfo.value.loggedIn;
    } catch (_) {
      // 非 ApiException (PlatformException / 解析失败) 也兜底清状态,
      // 否则 UI 连失败反馈都收不到
      authInfo.value = AuthInfo.empty();
      return false;
    }
  }

  Future<bool> logout() async {
    await _auth.logout();
    authInfo.value = AuthInfo.empty();
    return true;
  }

  /// 同步 uid + cookie 到 [authInfo]。uid 拿不到不算失败(只是 Library 拉不到
  /// 数据);cookies/flag 不全时**不清空也不硬写 true**(可能只是没网),
  /// 保留现有 Rx 由调用方决定 [logout]。
  Future<void> loadAuthInfo() async {
    final loggedIn = await _auth.isLoggedIn();
    final cookies = await _auth.getSavedAuthCookie();
    // fetchCurrentUid 内部 try/catch,失败返 0
    final uid = await _auth.fetchCurrentUid();

    if (loggedIn && cookies.isNotEmpty) {
      authInfo.value = AuthInfo(
        cookie: cookies,
        currentUid: uid,
        loggedIn: true,
      );
    } else {
      if (kDebugMode) {
        // ignore: avoid_print
        print(
          '[AuthController] loadAuthInfo: not fully logged in '
          '(loggedIn=$loggedIn, cookies=${cookies.length}, uid=$uid), '
          'keeping previous authInfo',
        );
      }
    }
  }
}
