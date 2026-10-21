import 'package:get/get.dart';

import '../../models/artist.dart';
import '../../models/album.dart';
import '../../models/song.dart';
import '../../sdk/api_call.dart';
import '../../models/api_exception.dart';
import '../../sdk/netease_api.dart';

/// 艺人 repository:只调 API + 解析。三路并行的编排(Future.wait + safeRun)
/// 是业务流程,归 [ArtistController]。
class ArtistRepository extends GetxService {
  final NeteaseApi _api;

  ArtistRepository(this._api);

  /// 拉艺人元信息 + 关注状态,null = API 失败或 artist 字段缺失。
  /// (响应外层包了一层 `{artist:{...}, hotSongs:[...]}`)
  Future<ArtistInfo?> fetchArtist(String artistId) async {
    try {
      final r = await apiCall(
        () => _api.callApi('artists', <Object?>[artistId]),
        what: '拉艺人信息',
      );
      final raw = r.body['artist'];
      if (raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final followed = m['followed'];
      return ArtistInfo(
        artist: Artist.fromNeteaseJson(m),
        followed: followed is bool ? followed : null,
      );
    } on ApiException {
      return null;
    }
  }

  /// 拉艺人专辑列表,空列表 = API 失败或列表字段缺失。
  /// (顶层字段 `hotAlbums` 或 `albums` 都见过,优先 hotAlbums)
  Future<List<Album>> fetchAlbums(String artistId) async {
    try {
      final r = await apiCall(
        () => _api.callApi('artist_album', <Object?>[artistId]),
        what: '拉艺人专辑',
      );
      final list = r.body['hotAlbums'] ?? r.body['albums'];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((m) => Album.fromNeteaseJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiException {
      return [];
    }
  }

  /// 拉艺人所有歌曲,空列表 = API 失败或 songs 字段缺失。
  Future<List<Song>> fetchSongs(String artistId, {int limit = 50}) async {
    try {
      final r = await apiCall(
        () =>
            _api.callApi('artist_songs', <Object?>[artistId, limit.toString()]),
        what: '拉艺人歌曲',
      );
      final list = r.body['songs'];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((m) => Song.fromNeteaseJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiException {
      return [];
    }
  }
}

/// 艺人元信息 + 关注状态
class ArtistInfo {
  final Artist artist;

  /// 后端返回的 `followed` 字段(true/false);null = 字段缺失
  final bool? followed;

  const ArtistInfo({required this.artist, this.followed});
}
