import 'package:get/get.dart';

import '../../sdk/api_call.dart';
import '../../models/api_exception.dart';
import '../../sdk/netease_api.dart';

/// "我收藏的专辑" repository —— 集中 album_sublist + album_sub 两个 API 调用
///
/// 把散落在 [LikedAlbumsService.loadFromServer] / [LikedAlbumsService.toggle]
/// 里的 `apiCall(() => api.raw.album_sublist(...))` / `album_sub(...)` 集中到这里。
///
/// - **不做** likedAlbumIds RxSet + 持久化 + 登录态联动 + snackbar 错误提示 —— 这些
///   是业务流程, 保留在 [LikedAlbumsService]。
/// - **只做**: 调 API + 解析 ids 字段。
///
/// **调试日志**:每个 fetch 方法都通过 `Get.log` 打印入参 / 响应关键字段 / 解析结果;
/// 异常 / 字段缺失用 `[WARN]` 前缀(GetX 4.7.3 没有 logW)。所有日志用
/// `Get.isLogEnable` 包住:release 自动关,debug 可手动设 true 全开。
class LikedRepository extends GetxService {
  final NeteaseApi _api;

  LikedRepository(this._api);

  static const _tag = 'LikedRepo';

  /// 拉收藏的专辑 id 全量列表。
  ///
  /// API: `/album/sublist`, 响应:
  /// ```
  /// { data: [{ id, ... }, ...], hasMore: ... }
  /// ```
  /// (顶层 data, 跟 /artist/sublist 同结构;跟 /user/playlist 的 `playlist` 不同)
  ///
  /// 返回 null: API 失败。返回空 Set: 拉成功但无收藏 / data 字段缺失。
  Future<Set<String>?> fetchLikedAlbumIds() async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] fetchLikedAlbumIds() enter');
    }
    try {
      final r = await apiCall(
        () => _api.callApi('album_sublist', const <Object?>[]),
        what: '拉收藏专辑',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] fetchLikedAlbumIds body keys=${r.body.keys.toList()}');
      }
      final list = r.body['data'];
      if (list is! List) {
        if (Get.isLogEnable) {
          Get.log(
            '[$_tag] [WARN] fetchLikedAlbumIds: body["data"] missing or not List '
            '(type=${list.runtimeType}); returning empty Set. '
            'full body=${r.body}',
          );
        }
        return <String>{};
      }
      final ids = list
          .whereType<Map>()
          .map((m) => m['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] fetchLikedAlbumIds: parsed count=${ids.length} '
          'sample=${ids.take(5).toList()}',
        );
      }
      return ids;
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] fetchLikedAlbumIds failed: $e');
      }
      return null;
    }
  }

  /// 收藏 / 取消收藏一张专辑。
  ///
  /// API: `/album/sub?id=X&t=1|0`
  /// 抛 [ApiException] (调用方决定是否 snackbar)。
  Future<void> toggleAlbumSub(String albumId, bool next) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] toggleAlbumSub id=$albumId next=$next');
    }
    try {
      await apiCall(
        () => _api.callApi('album_sub', <Object?>[albumId, next ? '1' : '0']),
        what: next ? '收藏专辑' : '取消收藏',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] toggleAlbumSub id=$albumId ok');
      }
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] toggleAlbumSub id=$albumId failed: $e');
      }
      rethrow;
    }
  }

  /// 拉收藏的歌单 id 全量列表。
  ///
  /// API: `/user/playlist?uid=X`, 响应:
  /// ```
  /// { playlist: [{ id, subscribed: bool, ... }, ...] }
  /// ```
  /// 只取 `subscribed == true` 的项 (用户自己创建的不算收藏)。
  ///
  /// 返回 null: API 失败。返回空 Set: 拉成功但无收藏 / playlist 字段缺失。
  Future<Set<String>?> fetchLikedPlaylistIds(String uid) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] fetchLikedPlaylistIds(uid=$uid) enter');
    }
    try {
      final r = await apiCall(
        () => _api.callApi('user_playlist', <Object?>[uid]),
        what: '拉收藏歌单',
      );
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] fetchLikedPlaylistIds body keys=${r.body.keys.toList()}',
        );
      }
      final list = r.body['playlist'];
      if (list is! List) {
        if (Get.isLogEnable) {
          Get.log(
            '[$_tag] [WARN] fetchLikedPlaylistIds: body["playlist"] missing or not List '
            '(type=${list.runtimeType}); returning empty Set. '
            'full body=${r.body}',
          );
        }
        return <String>{};
      }
      final ids = list
          .whereType<Map>()
          .where((m) => m['subscribed'] == true)
          .map((m) => m['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] fetchLikedPlaylistIds: total=${list.length} '
          'subscribed=${ids.length} sample=${ids.take(5).toList()}',
        );
      }
      return ids;
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] fetchLikedPlaylistIds failed: $e');
      }
      return null;
    }
  }

  /// 收藏 / 取消收藏一张歌单。
  ///
  /// API: `/playlist/subscribe?t=1|2&id=X` (t=1 收藏, t=2 取消)
  /// 抛 [ApiException] (调用方决定是否 snackbar)。
  Future<void> togglePlaylistSubscribe(String playlistId, bool next) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] togglePlaylistSubscribe id=$playlistId next=$next');
    }
    try {
      await apiCall(
        () => _api.callApi('playlist_subscribe', <Object?>[
          next ? '1' : '2',
          playlistId,
        ]),
        what: next ? '收藏歌单' : '取消收藏',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] togglePlaylistSubscribe id=$playlistId ok');
      }
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] [WARN] togglePlaylistSubscribe id=$playlistId failed: $e',
        );
      }
      rethrow;
    }
  }

  Future<Set<String>?> fetchLikedSongIds(String uid) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] fetchLikedSongIds(uid=$uid) enter');
    }
    try {
      final r = await apiCall(
        () => _api.callApi('likelist', <Object?>[uid]),
        what: '拉喜欢列表',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] fetchLikedSongIds body keys=${r.body.keys.toList()}');
      }
      final rawIds = r.body['ids'];
      if (rawIds is! List) {
        if (Get.isLogEnable) {
          Get.log(
            '[$_tag] [WARN] fetchLikedSongIds: body["ids"] missing or not List '
            '(type=${rawIds.runtimeType}); returning empty Set. '
            'full body=${r.body}',
          );
        }
        return <String>{};
      }
      final ids = rawIds.whereType<int>().map((i) => i.toString()).toSet();
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] fetchLikedSongIds: parsed count=${ids.length} '
          'sample=${ids.take(5).toList()}',
        );
      }
      return ids;
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] fetchLikedSongIds failed: $e');
      }
      return null;
    }
  }

  /// 喜欢 / 取消喜欢一首歌曲。
  ///
  /// API: `/like?id=X&like=true|false`
  /// 抛 [ApiException] (调用方决定是否 snackbar)。
  Future<void> toggleLike(String songId, bool next) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] toggleLike id=$songId next=$next');
    }
    try {
      await apiCall(
        () => _api.callApi('like', <Object?>[songId, next.toString()]),
        what: next ? '喜欢歌曲' : '取消喜欢',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] toggleLike id=$songId ok');
      }
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] toggleLike id=$songId failed: $e');
      }
      rethrow;
    }
  }

  /// 拉关注的艺人 id 全量列表。
  ///
  /// API: `/artist/sublist`, 响应顶层字段是 `data`(2026-08 实测样本:
  /// keys=[data, hasMore, count, code]);之前注释误标 `artists`,导致 likedArtistIds
  /// 一直空集、UI 显示"未关注"。
  ///
  /// 返回 null: API 失败。返回空 Set: 拉成功但无关注 / data 字段缺失。
  Future<Set<String>?> fetchLikedArtistIds() async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] fetchLikedArtistIds() enter');
    }
    try {
      final r = await apiCall(
        () => _api.callApi('artist_sublist', const <Object?>[]),
        what: '拉关注艺人',
      );
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] fetchLikedArtistIds body keys=${r.body.keys.toList()}',
        );
      }
      final rawArtists = r.body['data'];
      if (rawArtists is! List) {
        if (Get.isLogEnable) {
          Get.log(
            '[$_tag] [WARN] fetchLikedArtistIds: body["data"] missing or not List '
            '(type=${rawArtists.runtimeType}); returning empty Set. '
            'full body=${r.body}',
          );
        }
        return <String>{};
      }
      final ids = rawArtists
          .whereType<Map>()
          .map((m) => m['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
      if (Get.isLogEnable) {
        Get.log(
          '[$_tag] fetchLikedArtistIds: parsed count=${ids.length} '
          'sample=${ids.take(5).toList()}',
        );
      }
      return ids;
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] fetchLikedArtistIds failed: $e');
      }
      return null;
    }
  }

  /// 关注 / 取消关注一位艺人。
  ///
  /// API: `/artist/sub?id=X&t=1|0`
  /// 抛 [ApiException] (调用方决定是否 snackbar)。
  Future<void> toggleArtistSub(String artistId, bool next) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] toggleArtistSub id=$artistId next=$next');
    }
    try {
      await apiCall(
        () => _api.callApi('artist_sub', <Object?>[artistId, next ? '1' : '0']),
        what: next ? '关注艺人' : '取消关注',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] toggleArtistSub id=$artistId ok');
      }
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] toggleArtistSub id=$artistId failed: $e');
      }
      rethrow;
    }
  }

  /// 同步单个艺人的关注状态。
  ///
  /// API: `/artists?id=X`, 响应:
  /// ```
  /// { artist: { id, followed: bool, ... } }
  /// ```
  ///
  /// 返回 bool?: API 失败 → null; 成功 → artist.followed (缺则 null)。
  Future<bool?> fetchFollowed(String artistId) async {
    if (Get.isLogEnable) {
      Get.log('[$_tag] fetchFollowed(id=$artistId) enter');
    }
    try {
      final r = await apiCall(
        () => _api.callApi('artists', <Object?>[artistId]),
        what: '同步艺人关注状态',
      );
      if (Get.isLogEnable) {
        Get.log('[$_tag] fetchFollowed body keys=${r.body.keys.toList()}');
      }
      final raw = r.body['artist'];
      if (raw is! Map) {
        if (Get.isLogEnable) {
          Get.log(
            '[$_tag] [WARN] fetchFollowed id=$artistId: body["artist"] missing or not Map '
            '(type=${raw.runtimeType}); returning null. '
            'full body=${r.body}',
          );
        }
        return null;
      }
      final m = Map<String, dynamic>.from(raw);
      final followed = m['followed'];
      if (followed is! bool) {
        if (Get.isLogEnable) {
          Get.log(
            '[$_tag] [WARN] fetchFollowed id=$artistId: artist.followed missing or not bool '
            '(type=${followed.runtimeType}); returning null. artist=$m',
          );
        }
        return null;
      }
      if (Get.isLogEnable) {
        Get.log('[$_tag] fetchFollowed id=$artistId: followed=$followed');
      }
      return followed;
    } on ApiException catch (e) {
      if (Get.isLogEnable) {
        Get.log('[$_tag] [WARN] fetchFollowed id=$artistId failed: $e');
      }
      return null;
    }
  }
}
