// SPDX-License-Identifier: MIT

import 'dart:convert';

/// NCM API Enhanced 响应适配层。上游给
/// `{ status, body, cookie: List<String> }`,这里转成 app 内部统一用的
/// `{ status, body, headers }`。
class MusicResponse {
  MusicResponse({
    required this.status,
    required this.body,
    required this.headers,
  });

  /// 正常情况下恒为 200(传输层失败时上游才给 4xx/5xx)。
  final int status;

  final Map<String, dynamic> body;

  /// 只会填 `Set-Cookie`(上游就只给得出这个)。
  final Map<String, String> headers;

  String get cookies => headers['Set-Cookie'] ?? '';

  Map<String, dynamic> get data => body;

  /// cookie 是 list(上游可能发多条 Set-Cookie),这里用 `, ` 连起来。
  factory MusicResponse.fromNcm(Map<String, dynamic> raw) {
    final rawStatus = raw['status'];
    final status = rawStatus is int ? rawStatus : 200;
    final body =
        (raw['body'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final cookieList = raw['cookie'];
    String joined = '';
    if (cookieList is List) {
      joined = cookieList
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join(', ');
    } else if (cookieList is String) {
      joined = cookieList;
    }
    return MusicResponse(
      status: status,
      body: body,
      headers: joined.isEmpty
          ? <String, String>{}
          : <String, String>{'Set-Cookie': joined},
    );
  }

  Map<String, dynamic> toJson() => {
    'status': status,
    'body': body,
    'headers': headers,
  };

  String toJsonString() => jsonEncode(toJson());

  factory MusicResponse.fromJsonString(String s) {
    final m = jsonDecode(s) as Map<String, dynamic>;
    return MusicResponse(
      status: m['status'] as int? ?? 200,
      body: (m['body'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      headers: ((m['headers'] as Map?) ?? {}).cast<String, dynamic>().map(
        (k, v) => MapEntry(k, v?.toString() ?? ''),
      ),
    );
  }

  @override
  String toString() =>
      'MusicResponse(status=$status, body=${body.length} keys)';
}
