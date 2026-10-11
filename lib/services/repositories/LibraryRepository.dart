import 'package:get/get.dart';

import '../../models/LibrarySummary.dart';
import '../../sdk/ApiCall.dart';
import '../../models/ApiException.dart';
import '../../sdk/NeteaseApi.dart';

/// 首页推荐 + 我的页三个 tab 的 API 集中仓库,只负责调 API + 解析 + 返回强类型列表。
///
/// - **不做** RxList / isLoading / error 写回 —— 这些是业务流程,留在 controller。
class LibraryRepository extends GetxService {
  final NeteaseApi _api;

  LibraryRepository(this._api);

  /// 首页推荐歌单。
  ///
  /// API: /personalized?limit=30
  /// 返回空列表：API 失败 / result 字段缺失。
  Future<List<PlaylistCard>> fetchPersonalized() async {
    try {
      final r = await apiCall(
        () => _api.callApi('personalized', <Object?>['30']),
        what: '推荐歌单',
      );
      final list = r.body['result'];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map(
            (m) => PlaylistCard.fromNeteaseJson(Map<String, dynamic>.from(m)),
          )
          .toList();
    } on ApiException {
      return [];
    }
  }

  /// 我的歌单（含自建 + 收藏）。
  ///
  /// API: /user/playlist?uid=X&limit=50
  /// 返回空列表：API 失败 / playlist 字段缺失。
  ///
  /// `PlaylistSummary.source` 区分自建 vs 收藏,调用方（LibraryPage）
  /// 据此决定是否渲染红心 —— 自建歌单不显示红心。
  Future<List<PlaylistSummary>> fetchPlaylists(String uid) async {
    try {
      final r = await apiCall(
        () => _api.callApi('user_playlist', <Object?>[uid, '50']),
        what: '我的歌单',
      );
      final list = r.body['playlist'];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map(
            (m) =>
                PlaylistSummary.fromNeteaseJson(Map<String, dynamic>.from(m)),
          )
          .toList();
    } on ApiException {
      return [];
    }
  }

  /// 订阅的专辑。
  ///
  /// API: /album/sublist?limit=50
  /// 返回空列表：API 失败 / data 字段缺失。
  Future<List<AlbumSummary>> fetchSubscribedAlbums(String uid) async {
    try {
      final r = await apiCall(
        () => _api.callApi('album_sublist', <Object?>['50']),
        what: '我的订阅专辑',
      );
      final list = r.body['data'] is List
          ? r.body['data'] as List
          : (r.body is List ? r.body as List : const []);
      return list
          .whereType<Map>()
          .map(
            (m) => AlbumSummary.fromNeteaseJson(Map<String, dynamic>.from(m)),
          )
          .toList();
    } on ApiException {
      return [];
    }
  }

  /// 关注的艺人。
  ///
  /// API: /user/follow/mixed?size=50&cursor=0&scene=1
  /// 返回空列表：API 失败 / data.records 字段缺失。
  Future<List<ArtistSummary>> fetchFollowedArtists(String uid) async {
    try {
      final r = await apiCall(
        () => _api.callApi('user_follow_mixed', <Object?>['50', '0', '1']),
        what: '我的关注艺人',
      );
      final data = r.body['data'];
      final list = data is Map ? (data['records'] ?? data['list']) : data;
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((record) => record['artistInfo'])
          .whereType<Map>()
          .map(
            (m) => ArtistSummary.fromNeteaseJson(Map<String, dynamic>.from(m)),
          )
          .toList();
    } on ApiException {
      return [];
    }
  }
}
