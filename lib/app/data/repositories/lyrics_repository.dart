import 'package:get/get.dart';
import '../models/lyrics.dart';
import '../../../sdk/api_call.dart';
import '../models/api_exception.dart';
import '../../../sdk/netease_api.dart';

/// 歌词 repository。只调 `/lyric/new` + 解析 lrc/yrc/tlyric/romalrc 四个字段,
/// 不持有 lyric 缓存逻辑(在 LyricsController)和任何 UI 状态。
class LyricsRepository extends GetxService {
  final NeteaseApi _api;

  LyricsRepository(this._api);

  /// lrc 和 yrc 都空才算没有歌词(没有歌词的歌上游只返回制作信息)。
  Future<Lyrics?> _fetch(String songId) async {
    try {
      final r = await apiCall(
        () => _api.callApi('lyric_new', <Object?>[songId]),
        what: '取歌词',
      );
      String pick(String key) =>
          (r.body[key]?['lyric'] as String?)?.toString() ?? '';
      final lrc = pick('lrc');
      final yrc = pick('yrc');
      if (lrc.trim().isEmpty && yrc.trim().isEmpty) return null;
      return Lyrics(
        lrc: lrc,
        yrc: yrc,
        tlyric: pick('tlyric'),
        romalrc: pick('romalrc'),
      );
    } on ApiException {
      return null;
    }
  }

  final Map<String, Lyrics?> _cache = {};

  /// 拉 songId 的歌词,失败 / 都空 → null。
  Future<Lyrics?> fetch(String songId) async {
    final cached = _cache[songId];
    if (cached != null) return cached;
    final lyric = await _fetch(songId);
    if (lyric != null) {
      _cache[songId] = lyric;
    }
    return lyric;
  }

  /// 清缓存(用户手动刷新歌词时);不传 songId 就全清。
  void invalidate([String? songId]) {
    if (songId == null) {
      _cache.clear();
    } else {
      _cache.remove(songId);
    }
  }
}
