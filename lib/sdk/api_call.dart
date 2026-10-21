import 'dart:async';

import '../models/api_exception.dart';
import 'music_response.dart';

/// 调一次接口:把 RPC / 解析 / 网络异常统一包成 [ApiException],
/// 并做 [checkResponse] 业务检查。
Future<MusicResponse> apiCall(
  Future<MusicResponse> Function() fn, {
  String? what,
}) async {
  try {
    final r = await fn();
    checkResponse(r, hint: what);
    return r;
  } on ApiException {
    rethrow;
  } catch (e) {
    throw ApiException(
      ApiException.localUnexpected,
      '${what ?? "API"} 调用失败: $e',
      cause: e,
    );
  }
}

/// 业务成功判定:HTTP 200 + body.code 200(网易云惯例)。
///
/// code 缺失是允许的(部分 banner / settings 没有),此时只看 HTTP status。
/// 两层 body 都要查:`/playlist/tracks` 等端点的 code 不在顶层而在
/// `r.body['body']['code']`。
void checkResponse(MusicResponse r, {String? hint}) {
  if (r.status != 200) {
    throw ApiException(r.status, '${hint ?? "请求"} 失败 (HTTP ${r.status})');
  }
  final bodyCode = r.body['code'] ?? r.body['body']?['code'];
  if (bodyCode is int && bodyCode != 200) {
    final msg =
        r.body['message'] ??
        r.body['msg'] ??
        r.body['body']?['message'] ??
        r.body['body']?['msg'] ??
        '未知业务错误';
    throw ApiException(bodyCode, '${hint ?? "请求"} 失败: $msg', rawBody: r.body);
  }
}
