import 'package:get/get.dart';

import '../../sdk/ApiCall.dart';
import '../../models/ApiException.dart';
import '../../sdk/NeteaseApi.dart';
import '../../SettingsPage/SettingsController.dart';

/// Song repository:只调 API + 提取字段。http→https 转换、空 URL 判断、
/// snackbar 提示这些归调用方。
///
/// `level` 省略时取全局 [SettingsController.currentQuality],调用方可以显式
/// 覆盖(例如下载想用低码率省流量)。
class SongRepository extends GetxService {
  final NeteaseApi _api;
  final SettingsController _settings;

  SongRepository(this._api, this._settings);

  /// 拉单首的临时直链,null = API 失败或该歌取不到地址。
  Future<String?> fetchSongUrl(String songId, {String? level}) async {
    final map = await fetchSongUrls([songId], level: level);
    return map[songId];
  }

  /// 批量拉直链 → `songId → url`。`id` 参数支持逗号分隔,整张播放列表一次问完。
  ///
  /// 正常路径走 LocalRedirectServer,压根不用在这里解析地址;批量只服务于
  /// 降级路径(server 没起来 / web),那里队列地址必须提前解析,几百首逐首请求
  /// 会卡住 UI。
  ///
  /// 返回的 map **不含取不到地址的歌**(VIP / 地区限制 / 未登录),调用方自己
  /// 处理缺项。
  Future<Map<String, String>> fetchSongUrls(
    List<String> songIds, {
    String? level,
  }) async {
    if (songIds.isEmpty) return const {};
    final effectiveLevel = level ?? _settings.currentQuality.value.name;
    try {
      final r = await apiCall(
        () => _api.callApi('song_url_v1', <Object?>[
          songIds.join(','),
          effectiveLevel,
        ]),
        what: '取播放 URL',
      );
      final data = r.body['data'];
      if (data is! List) return const {};
      final out = <String, String>{};
      for (final entry in data) {
        if (entry is! Map) continue;
        final rawId = entry['id'];
        final id = rawId is String || rawId is num ? rawId.toString() : null;
        final rawUrl = entry['url'] as String?;
        if (id == null || rawUrl == null || rawUrl.isEmpty) continue;
        out[id] = rawUrl.startsWith('http://')
            ? rawUrl.replaceFirst('http://', 'https://')
            : rawUrl;
      }
      return out;
    } on ApiException {
      return const {};
    }
  }

  /// 批量补封面 → `songId → picUrl`(只含非空的)。调用方负责回填 Song。
  Future<Map<String, String>> fetchSongDetails(List<String> songIds) async {
    if (songIds.isEmpty) return {};
    try {
      final ids = songIds.join(',');
      final r = await apiCall(
        () => _api.callApi('song_detail', <Object?>[ids]),
        what: '补单曲封面',
      );
      final songs = r.body['songs'];
      if (songs is! List) return {};
      final byId = <String, String>{};
      for (final raw in songs) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final sid = m['id']?.toString();
        if (sid == null) continue;
        final al = m['al'] ?? m['album'];
        if (al is! Map) continue;
        final picUrl = (Map<String, dynamic>.from(al)['picUrl'] ?? '')
            .toString();
        if (picUrl.isNotEmpty) byId[sid] = picUrl;
      }
      return byId;
    } on ApiException {
      return {};
    }
  }
}
