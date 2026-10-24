// SPDX-License-Identifier: MIT
//
// 网易云 API facade —— 仓库层 / UI 层的唯一入口。
//
// 链路:NeteaseApi → NcmApi(进程内)→ 内嵌 node bridge(NDJSON over
// stdin/stdout 或 platform channel)。没有 worker isolate:IPC 本身已经异步,
// 不需要再套一层。cookie 状态因此直接活在主 isolate。

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

import 'api_call.dart';
import 'method_spec.dart';
import 'music_response.dart';

/// 持有 [NcmApi] 实例 + cookie 状态(内存 + GetStorage 持久化)。
/// 仓库层调 `callApi(method, [位置参数])`,由 [positionalToQuery] 翻成 query dict。
///
/// main 里 `await initNeteaseApi()` 启动,各处用 `Get.find<NeteaseApi>()` 拿。
class NeteaseApi extends GetxService {
  static const _loggedInKey = 'netease_logged_in_v1';
  static const _cookieStorageKey = 'netease_cookie_v1';
  static const _anonCookieStorageKey = 'netease_anon_cookie_v1';

  final NcmApi _ncm = NcmApi();

  /// cookie / 登录态统一放 default box,持久化的 key 见下面的常量。
  GetStorage get _box => GetStorage();

  /// 已生效的身份 cookie,内存里同步读,变更时写盘。
  Map<String, String> _authCookie = const {};
  Map<String, String> _anonCookie = const {};

  // region 登录流程 API

  /// 发送验证码。
  Future<void> sendCaptcha({
    required String phone,
    String ctcode = '86',
  }) async {
    await apiCall(
      () => _callRaw('captcha_sent', <Object?>[phone, ctcode]),
      what: '发送验证码',
    );
  }

  /// 登录(走 captcha 验证码分支)。
  ///
  /// 返回原始 [MusicResponse] — 调用方 ([applyLoginCookie]) 负责把
  /// Set-Cookie 持久化。
  Future<MusicResponse> loginCellphone({
    required String phone,
    required String captcha,
    String countrycode = '86',
  }) async {
    return apiCall(
      () => _callRaw('login_cellphone', <Object?>[phone, captcha, countrycode]),
      what: '登录',
    );
  }

  /// 拉取并应用**游客 cookie**(`/register/anonimous`)。
  Future<void> applyAnonymousCookie() async {
    try {
      final r = await _callRaw('register_anonimous', const <Object?>[]);
      final cookies = <String, String>{};
      cookies.addAll(parseCookieString(r.cookies));
      _mergeBodyCookies(r.body['cookie'], cookies);
      if (cookies.isEmpty) {
        if (kDebugMode) {
          // ignore: avoid_print
          print(
            '[NeteaseApi] applyAnonymousCookie: register_anonimous 返 200 '
            '但没拿到 cookie (body.keys=${r.body.keys.toList()}, '
            'status=${r.status})',
          );
        }
        return;
      }
      _anonCookie = cookies;
      _box.write(_anonCookieStorageKey, cookies);
      if (kDebugMode) {
        // ignore: avoid_print
        print('[NeteaseApi] applyAnonymousCookie OK: ${cookies.keys.toList()}');
      }
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[NeteaseApi] applyAnonymousCookie failed: $e');
      }
    }
  }

  /// 把登录响应的 Set-Cookie 解析并持久化。
  Future<Map<String, String>> applyLoginCookie(MusicResponse response) async {
    final cookies = parseCookieString(response.cookies);
    if (cookies.isEmpty) return const {};
    _authCookie = cookies;
    _box.write(_cookieStorageKey, cookies);
    _box.write(_loggedInKey, true);
    return cookies;
  }

  /// 拉取并缓存当前登录用户的 uid(/user/account)。
  /// 失败仅打日志不抛 — uid 拿不到只影响 Library 页拉数据。
  Future<int> fetchCurrentUid() async {
    try {
      final r = await apiCall(
        () => _callRaw('user_account', const <Object?>[]),
        what: '获取当前用户 uid',
      );
      dynamic data = r.body['data'] ?? r.body;
      int? uid;
      if (data is Map) {
        final account = data['account'];
        if (account is Map && account['id'] is int) {
          uid = account['id'] as int;
        }
        if (uid == null && data['id'] is int) {
          uid = data['id'] as int;
        }
      }
      if (uid == null || uid <= 0) {
        if (kDebugMode) {
          // ignore: avoid_print
          print(
            '[NeteaseApi] fetchCurrentUid: unexpected body shape ${r.body}',
          );
        }
        return 0;
      }
      _box.write('netease_uid_v1', uid);
      return uid;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[NeteaseApi] fetchCurrentUid failed: $e');
      }
      return 0;
    }
  }

  /// 拉 /login/status 拿 cookie map (用于 UI 订阅)。
  Future<Map<String, String>> getCookiesByCheckLogin() async {
    final r = await apiCall(
      () => _callRaw('login_status', const <Object?>[]),
      what: '获取登录状态',
    );
    return parseCookieString(r.cookies);
  }

  /// 退出登录:清 cookie + 持久化。
  Future<void> logout() async {
    _authCookie = const {};
    _box.remove(_cookieStorageKey);
    _box.remove(_anonCookieStorageKey);
    _box.write(_loggedInKey, false);
  }

  Future<bool> isLoggedIn() async => _box.read<bool>(_loggedInKey) ?? false;

  Future<Map<String, String>> getSavedAuthCookie() async {
    final raw = _box.read<Map>(_cookieStorageKey);
    if (raw == null || raw.isEmpty) return const {};
    return <String, String>{
      for (final e in raw.entries) e.key.toString(): e.value.toString(),
    };
  }

  // endregion

  /// 启动初始化:
  /// 1. 启动 [NcmApi] (spawn node 进程 / init libnode.so)
  /// 2. 恢复持久化的 cookie + loggedIn flag
  /// 3. 如果未登录且无匿名 cookie,启动阶段拉一次访客 cookie
  Future<void> init() async {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[NeteaseApi] init');
    }
    await _ncm.start();

    final box = _box;
    final loggedIn = box.read<bool>(_loggedInKey) ?? false;
    final authCookie = box.read<Map>(_cookieStorageKey);
    final anonCookie = box.read<Map>(_anonCookieStorageKey);

    if (authCookie != null && authCookie.isNotEmpty) {
      _authCookie = authCookie.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    if (anonCookie != null && anonCookie.isNotEmpty) {
      _anonCookie = anonCookie.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    if (kDebugMode) {
      // ignore: avoid_print
      print(
        '[NeteaseApi] restored loggedIn=$loggedIn, '
        'authCookie=${_authCookie.length}, anonCookie=${_anonCookie.length}',
      );
    }

    if (!loggedIn && _anonCookie.isEmpty) {
      await applyAnonymousCookie();
    }
  }

  /// 仓库层调用。`method` 是 SDK 方法名(如 'playlist_detail'),`params` 是
  /// 位置参数列表(映射见 MethodSpec.methodSpecs)。
  Future<MusicResponse> callApi(String method, List<Object?> params) {
    return _callRaw(method, params);
  }

  Future<MusicResponse> _callRaw(String method, List<Object?> params) async {
    final query = positionalToQuery(method, params);
    // Attach the held identity cookie so upstream can recognise the caller.
    //
    // Upstream's util/option.js reads `query.cookie` before falling back to
    // NETEASE_COOKIE env. Without this every call hits NCM anonymously →
    // user_account returns null, library fetches get 301, etc.
    //
    // Order: caller-provided `cookie` wins, then auth (login), then anon
    // (visitor), then empty. Pass `cookie: ''` to suppress cookies.
    final hasCallerCookie =
        query.containsKey('cookie') && query['cookie'] != null;
    if (!hasCallerCookie) {
      final cookie = _authCookie.isNotEmpty ? _authCookie : _anonCookie;
      query['cookie'] = cookie;
    }
    final raw = await _ncm.call(method, query);
    return MusicResponse.fromNcm(raw);
  }

  Future<void>? _shutdownFuture;

  /// 关掉内嵌 node bridge（桌面端是真实子进程）。幂等。
  ///
  /// 退出路径必须 await：Flutter 先退出会把 node 留成孤儿进程。
  Future<void> shutdown() => _shutdownFuture ??= _ncm.shutdown();

  /// 整个 app 退出时调用。
  @override
  void onClose() {
    unawaited(shutdown());
    super.onClose();
  }

  /// 解析 `Set-Cookie` 字符串为 key/value map。跳过 `Path` / `Expires` 这类
  /// 非身份字段,只保留 PascalCase 的 cookie 名。
  static Map<String, String> parseCookieString(String s) {
    final result = <String, String>{};
    if (s.isEmpty) return result;
    for (final raw in s.split(',')) {
      final parts = raw.split(';');
      for (final p in parts) {
        final t = p.trim();
        final eq = t.indexOf('=');
        if (eq <= 0) continue;
        var key = t.substring(0, eq).trim();
        final value = t.substring(eq + 1).trim();
        key = key.replaceAll(RegExp(r'^[^A-Za-z0-9_]+'), '');
        key = key.replaceAll(RegExp(r'[^A-Za-z0-9_]+$'), '');
        if (key.isEmpty) continue;
        if (key[0].toUpperCase() != key[0]) continue;
        if (key.toLowerCase() == 'path' ||
            key.toLowerCase() == 'expires' ||
            key.toLowerCase() == 'httponly' ||
            key.toLowerCase() == 'samesite' ||
            key.toLowerCase() == 'max-age' ||
            key.toLowerCase() == 'domain' ||
            key.toLowerCase() == 'secure') {
          continue;
        }
        result[key] = value;
      }
    }
    return result;
  }

  /// 合并上游 NCM API 的 body.cookie map 进 cookies dict。
  ///
  /// 网易云 `/register/anonimous` 等接口除了 Set-Cookie 头外,body 里
  /// 也可能含一个 `cookie: '...'` 字符串,这里把 body 那个也合并进
  /// cookies dict(取并集,后写优先)。
  static void _mergeBodyCookies(
    Object? bodyCookie,
    Map<String, String> cookies,
  ) {
    if (bodyCookie is String && bodyCookie.isNotEmpty) {
      cookies.addAll(parseCookieString(bodyCookie));
    } else if (bodyCookie is Map) {
      for (final e in bodyCookie.entries) {
        cookies[e.key.toString()] = e.value?.toString() ?? '';
      }
    }
  }
}

/// 一次性 init 入口(给 main.dart 用)。
///
/// 调用顺序(main.dart):
/// 1. `await GetStorage.init()`
/// 2. `await initNeteaseApi()` — 创建 facade + 启动 NcmApi + 灌回 cookie
Future<void> initNeteaseApi() async {
  if (Get.isRegistered<NeteaseApi>()) return;
  Get.put<NeteaseApi>(NeteaseApi(), permanent: true);
  await Get.find<NeteaseApi>().init();
}
