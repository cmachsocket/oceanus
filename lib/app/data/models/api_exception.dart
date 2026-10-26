/// 网易云 API 业务异常。`code < 0` 是本地异常(见下面的 localXxx),
/// `code >= 0` 是后端业务码(body['code'] 或 HTTP status)。
class ApiException implements Exception {
  final int code;
  final String message;
  final Object? cause;

  /// 校准用:`checkResponse` 因 body.code != 200 抛异常时带出的完整 body。
  /// 只有业务码错误才有;网络 / HTTP status / 解析失败都是 null。
  final Map<String, dynamic>? rawBody;

  const ApiException(this.code, this.message, {this.cause, this.rawBody});

  static const int localNetwork = -1;
  static const int localParse = -2;
  static const int localUnexpected = -99;

  @override
  String toString() => 'ApiException($code): $message';
}
