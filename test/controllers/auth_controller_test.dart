import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oceanus/sdk/auth_controller.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNcmBridge bridge;
  late AuthController controller;

  /// 默认桩:游客 cookie + 登录 cookie + 用户 uid。
  ///
  /// 走 bridge 层而不是 `callApi` —— 登录 / 验证码这些是 [AuthController] 直接
  /// 调 [NeteaseApi] 自己的方法,不经过 `callApi`。
  Map<String, dynamic> defaultResponder(String method) {
    switch (method) {
      case 'register_anonimous':
        return <String, dynamic>{
          'status': 200,
          'body': <String, dynamic>{'code': 200},
          'cookie': <String>['NMTID=anon-id; Path=/;'],
        };
      case 'login_cellphone':
        return <String, dynamic>{
          'status': 200,
          'body': <String, dynamic>{'code': 200},
          'cookie': <String>['MUSIC_U=login-token; Path=/; HttpOnly'],
        };
      case 'user_account':
        return <String, dynamic>{
          'status': 200,
          'body': <String, dynamic>{
            'code': 200,
            'data': <String, dynamic>{
              'account': <String, dynamic>{'id': 12345},
            },
          },
        };
      default:
        return <String, dynamic>{
          'status': 200,
          'body': <String, dynamic>{'code': 200},
        };
    }
  }

  Future<void> boot([
    Map<String, dynamic> Function(String method, Map<String, dynamic>? params)?
    responder,
  ]) async {
    bridge = FakeNcmBridge(
      responder ?? ((method, params) => defaultResponder(method)),
    );
    await bootstrapGetX(bridge: bridge);
    controller = Get.find<AuthController>();
  }

  setUp(clearTestStorage);
  tearDown(teardownGetX);

  group('login', () {
    test('成功后写入 cookie、标记已登录并拉到 uid', () async {
      await boot();

      final ok = await controller.login(
        phoneStr: '13800000000',
        codeStr: '1234',
        countryCode: '86',
      );

      expect(ok, isTrue);
      expect(controller.loggedIn, isTrue);
      expect(controller.currentUid, 12345);
      expect(
        GetStorage().read<Map<String, String>>('netease_cookie_v1'),
        containsPair('MUSIC_U', 'login-token'),
      );
    });

    test('登录响应没带 cookie 时视为失败', () async {
      await boot((method, params) {
        if (method == 'login_cellphone') {
          return <String, dynamic>{
            'status': 200,
            'body': <String, dynamic>{'code': 200},
          };
        }
        return defaultResponder(method);
      });

      final ok = await controller.login(
        phoneStr: '13800000000',
        codeStr: '1234',
        countryCode: '86',
      );

      expect(ok, isFalse);
      expect(controller.loggedIn, isFalse);
    });

    test('上游抛异常时返回 false 而不是把异常抛出去', () async {
      await bootstrapGetX(
        bridge: FakeNcmBridge((method, params) => throw StateError('boom')),
      );
      controller = Get.find<AuthController>();

      final ok = await controller.login(
        phoneStr: '13800000000',
        codeStr: '1234',
        countryCode: '86',
      );

      expect(ok, isFalse);
      expect(controller.loggedIn, isFalse);
    });

    test('先拉游客 cookie 再发登录请求', () async {
      await boot();

      await controller.login(
        phoneStr: '13800000000',
        codeStr: '1234',
        countryCode: '86',
      );

      final methods = bridge.calls.map((c) => c.method).toList();
      expect(
        methods.indexOf('register_anonimous'),
        lessThan(methods.indexOf('login_cellphone')),
      );
    });
  });

  group('sendCode', () {
    test('成功时返回 true', () async {
      await boot();

      expect(
        await controller.sendCode(phoneStr: '13800000000', countryCode: '86'),
        isTrue,
      );
      expect(bridge.calls.single.method, 'captcha_sent');
    });

    test('上游抛异常时返回 false', () async {
      await bootstrapGetX(
        bridge: FakeNcmBridge((method, params) => throw StateError('boom')),
      );
      controller = Get.find<AuthController>();

      expect(
        await controller.sendCode(phoneStr: '13800000000', countryCode: '86'),
        isFalse,
      );
    });
  });

  group('logout', () {
    test('清掉本地登录态', () async {
      await boot();
      await controller.login(
        phoneStr: '13800000000',
        codeStr: '1234',
        countryCode: '86',
      );

      await controller.logout();

      expect(controller.loggedIn, isFalse);
      expect(controller.currentUid, 0);
    });
  });

  group('loadAuthInfo', () {
    test('cookie 不全时保留原有状态,不硬写成已登录', () async {
      await boot();
      GetStorage().write('netease_logged_in_v1', true);

      await controller.loadAuthInfo();

      expect(controller.loggedIn, isFalse);
    });
  });
}
