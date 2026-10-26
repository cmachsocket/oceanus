import 'package:get/get.dart';

import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../../../sdk/api_call.dart';
import '../models/api_exception.dart';
import '../../../sdk/netease_api.dart';

/// `/search` 的 type 参数,以及响应 `result.<resultKey>` 的取值。
enum SearchType {
  song(1, 'songs', '单曲'),
  album(10, 'albums', '专辑'),
  artist(100, 'artists', '艺人'),
  playlist(1000, 'playlists', '歌单');

  const SearchType(this.typeId, this.resultKey, this.label);

  final int typeId;
  final String resultKey;
  final String label;
}

/// Search repository:只调 `/search` + 解析。RxList / isLoading / snackbar /
/// 竞争处理这些业务流程归 [SearchController]。
class SearchRepository extends GetxService {
  final NeteaseApi _api;

  SearchRepository(this._api);

  /// 拉搜索结果,null = API 失败或响应结构缺失。
  /// 响应形如 `{ result: { songs|albums|artists|playlists: [...] } }`。
  Future<SearchResult?> search({
    required String keywords,
    required SearchType type,
    int limit = 30,
  }) async {
    try {
      final r = await apiCall(
        () => _api.callApi('search', <Object?>[
          keywords,
          type.typeId.toString(),
          limit.toString(),
        ]),
        what: '搜索',
      );
      final result = r.body['result'];
      if (result is! Map) return null;
      final list = result[type.resultKey];
      if (list is! List) return null;
      final items = list.whereType<Map>().toList();
      switch (type) {
        case SearchType.song:
          return SearchResult(
            songs: items
                .map((m) => Song.fromNeteaseJson(Map<String, dynamic>.from(m)))
                .toList(),
          );
        case SearchType.album:
          return SearchResult(
            albums: items
                .map((m) => Album.fromNeteaseJson(Map<String, dynamic>.from(m)))
                .toList(),
          );
        case SearchType.artist:
          // 搜索接口的 artists[] 项是裸 artist,没有 /artists 接口那层 wrap
          return SearchResult(
            artists: items
                .map(
                  (m) => Artist.fromNeteaseJson(Map<String, dynamic>.from(m)),
                )
                .toList(),
          );
        case SearchType.playlist:
          return SearchResult(
            playlists: items
                .map(
                  (m) => SearchPlaylistSummary.fromNeteaseJson(
                    Map<String, dynamic>.from(m),
                  ),
                )
                .toList(),
          );
      }
    } on ApiException {
      return null;
    }
  }
}

/// 4 种 type 各自一份 nullable List,调用方按 [SearchType] 读对应字段。
class SearchResult {
  final List<Song>? songs;
  final List<Album>? albums;
  final List<Artist>? artists;
  final List<SearchPlaylistSummary>? playlists;

  const SearchResult({this.songs, this.albums, this.artists, this.playlists});
}

/// 搜索结果里的歌单摘要。不跟 LibraryController 的 PlaylistSummary 合并 ——
/// 搜索结果没有 userId 等 user-only 字段,放一起会污染。
class SearchPlaylistSummary {
  final String id;
  final String name;
  final String coverUrl;
  final int trackCount;
  final String creatorName;

  const SearchPlaylistSummary({
    required this.id,
    required this.name,
    required this.coverUrl,
    required this.trackCount,
    required this.creatorName,
  });

  /// `/search?type=1000` 的 `result.playlists[]` 元素。
  factory SearchPlaylistSummary.fromNeteaseJson(Map<String, dynamic> json) {
    final creator = json['creator'] is Map
        ? Map<String, dynamic>.from(json['creator'] as Map)
        : null;
    return SearchPlaylistSummary(
      id: json['id'].toString(),
      name: (json['name'] ?? '').toString(),
      coverUrl: (json['coverImgUrl'] ?? '').toString(),
      trackCount: (json['trackCount'] as int?) ?? 0,
      creatorName: (creator?['nickname'] ?? '').toString(),
    );
  }
}
