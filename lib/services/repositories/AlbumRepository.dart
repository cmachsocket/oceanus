import 'package:get/get.dart';

import '../../models/Song.dart';
import '../../sdk/ApiCall.dart';
import '../../models/ApiException.dart';
import '../../sdk/NeteaseApi.dart';

/// 专辑 repository:只调 `/album` + 解析。响应同时含 album 项和 songs 数组,
/// 一次 fetch 就够。Rx 写回是业务状态,归 controller。
class AlbumRepository extends GetxService {
  final NeteaseApi _api;

  AlbumRepository(this._api);

  /// 拉专辑内容(元信息 + 所有曲目),null = API 失败或 album 字段缺失。
  Future<AlbumContent?> fetch(String albumId) async {
    try {
      final r = await apiCall(
        () => _api.callApi('album', <Object?>[albumId]),
        what: '拉专辑内容',
      );
      final albumMap = r.body['album'];
      if (albumMap is! Map) return null;
      final a = Map<String, dynamic>.from(albumMap);
      final songsList = r.body['songs'];
      final songs = songsList is List
          ? songsList
                .whereType<Map>()
                .map((m) => Song.fromNeteaseJson(Map<String, dynamic>.from(m)))
                .toList()
          : <Song>[];
      return AlbumContent(
        name: (a['name'] ?? '').toString(),
        coverUrl: (a['picUrl'] ?? '').toString(),
        description: (a['description'] ?? '').toString(),
        songs: songs,
      );
    } on ApiException {
      return null;
    }
  }
}

/// 专辑内容 (name/coverUrl/description + 所有曲目)
class AlbumContent {
  final String name;
  final String coverUrl;
  final String description;
  final List<Song> songs;

  const AlbumContent({
    required this.name,
    required this.coverUrl,
    required this.description,
    required this.songs,
  });
}
