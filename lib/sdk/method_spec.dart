// SPDX-License-Identifier: MIT
//
// SDK method → query dict 字段映射。
//
// 上游 NCM API(`@neteasecloudmusicapienhanced/api`)每次调用只吃一个
// `Map<String, dynamic>`,key 就是 HTTP query 字段名。这里负责把仓库层的
// 位置参数翻成那个 dict。
//
// 字段名与上游 `interface.d.ts` 一致(snake_case),上游签名变了要同步改这里。

import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

/// 一个位置参数槽。`defaultIfMissing` 是参数缺省时填的默认值;
/// `dropIfNull`(默认 false)决定 null 是原样写进 dict 还是整个省略 ——
/// 有些端点不接受显式 null。
class ParamSlot {
  const ParamSlot(this.field, {this.defaultIfMissing, this.dropIfNull = false});
  final String field;
  final String? defaultIfMissing;
  final bool dropIfNull;
}

class MethodSpec {
  const MethodSpec({
    required this.method,
    required this.params,
    this.requiresAuth = false,
  });

  final String method;
  final List<ParamSlot> params;
  final bool requiresAuth;
}

/// 分发表。加新方法只往这里追加一条,[NeteaseApi.callApi] 按名字查表。
const List<MethodSpec> methodSpecs = [
  MethodSpec(
    method: 'captcha_sent',
    params: [
      ParamSlot('phone'),
      ParamSlot('ctcode', defaultIfMissing: '86'),
    ],
  ),
  MethodSpec(
    method: 'login_cellphone',
    params: [
      ParamSlot('phone'),
      ParamSlot('captcha'),
      ParamSlot('countrycode', defaultIfMissing: '86'),
    ],
  ),
  MethodSpec(method: 'register_anonimous', params: []),
  MethodSpec(method: 'user_account', params: []),
  MethodSpec(method: 'login_status', params: []),
  MethodSpec(method: 'playlist_detail', params: [ParamSlot('id')]),
  MethodSpec(
    method: 'playlist_track_all',
    params: [ParamSlot('id'), ParamSlot('limit'), ParamSlot('offset')],
  ),
  MethodSpec(
    method: 'playlist_create',
    params: [ParamSlot('name'), ParamSlot('privacy'), ParamSlot('type')],
  ),
  // playlist_tracks(op, pid, tracks) — upstream takes the same names;
  // the SDK had them positional but they're already the upstream fields.
  MethodSpec(
    method: 'playlist_tracks',
    params: [ParamSlot('op'), ParamSlot('pid'), ParamSlot('tracks')],
  ),
  MethodSpec(method: 'playlist_delete', params: [ParamSlot('id')]),
  MethodSpec(
    method: 'playlist_subscribe',
    params: [ParamSlot('t'), ParamSlot('id')],
  ),
  MethodSpec(method: 'album', params: [ParamSlot('id')]),
  MethodSpec(
    method: 'album_sublist',
    params: [ParamSlot('limit', defaultIfMissing: '50')],
  ),
  MethodSpec(method: 'album_sub', params: [ParamSlot('id'), ParamSlot('t')]),
  MethodSpec(method: 'artists', params: [ParamSlot('id')]),
  MethodSpec(method: 'artist_sublist', params: []),
  MethodSpec(method: 'artist_sub', params: [ParamSlot('id'), ParamSlot('t')]),
  MethodSpec(method: 'artist_album', params: [ParamSlot('id')]),
  MethodSpec(
    method: 'artist_songs',
    params: [
      ParamSlot('id'),
      ParamSlot('limit', defaultIfMissing: '50'),
    ],
  ),
  MethodSpec(method: 'likelist', params: [ParamSlot('uid')]),
  MethodSpec(method: 'like', params: [ParamSlot('id'), ParamSlot('like')]),
  MethodSpec(method: 'lyric_new', params: [ParamSlot('id')]),
  MethodSpec(
    method: 'search',
    params: [
      ParamSlot('keywords'),
      ParamSlot('type', defaultIfMissing: '1'),
      ParamSlot('limit', defaultIfMissing: '30'),
    ],
  ),
  // song_url 已弃用, 改用 song_url_v1 (按音质等级而非码率)。
  MethodSpec(
    method: 'song_url_v1',
    params: [ParamSlot('id'), ParamSlot('level')],
  ),
  MethodSpec(method: 'song_detail', params: [ParamSlot('ids')]),
  MethodSpec(
    method: 'personalized',
    params: [ParamSlot('limit', defaultIfMissing: '30')],
  ),
  MethodSpec(
    method: 'user_playlist',
    params: [
      ParamSlot('uid'),
      ParamSlot('limit', defaultIfMissing: '50'),
    ],
  ),
  MethodSpec(
    method: 'user_follow_mixed',
    params: [
      ParamSlot('size', defaultIfMissing: '50'),
      ParamSlot('cursor', defaultIfMissing: '0'),
      ParamSlot('scene', defaultIfMissing: '1'),
    ],
  ),
];

final Map<String, MethodSpec> _byMethod = {
  for (final s in methodSpecs) s.method: s,
};

/// 按名字查 spec。查不到基本等于"加了 SDK 方法但忘了更新 [methodSpecs]",
/// 直接抛而不是静默返回空。
MethodSpec specFor(String method) {
  final s = _byMethod[method];
  if (s == null) {
    throw ArgumentError(
      'NcmApi spec: no entry for "$method". Add it to methodSpecs '
      'in lib/sdk/MethodSpec.dart (28 entries currently).',
    );
  }
  return s;
}

/// 位置参数列表 → 上游 query dict。缺省值由 [ParamSlot.defaultIfMissing] 补,
/// 调用方可以省掉常用参数。
Map<String, dynamic> positionalToQuery(String method, List<Object?> args) {
  final spec = specFor(method);
  final out = <String, dynamic>{};
  for (var i = 0; i < spec.params.length; i++) {
    final slot = spec.params[i];
    final value = i < args.length ? args[i] : null;
    if (value == null) {
      if (slot.defaultIfMissing != null) {
        out[slot.field] = slot.defaultIfMissing;
      } else if (!slot.dropIfNull) {
        out[slot.field] = null;
      }
    } else {
      out[slot.field] = value;
    }
  }
  return out;
}

/// 已经有 query dict、不需要位置参数翻译时的快捷方式。
Future<Map<String, dynamic>> callRaw(
  NcmApi api,
  String method,
  Map<String, dynamic>? query,
) => api.call(method, query);
