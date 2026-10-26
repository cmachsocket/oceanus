import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../models/library_summary.dart' show PlaylistSource;
import '../models/song.dart';
import '../../../sdk/api_call.dart';
import '../models/api_exception.dart';
import '../../../sdk/netease_api.dart';
import '../../../sdk/music_response.dart';
import '../models/playlist.dart';
import '../../services/playlist_events_controller.dart';

/// 歌单 repository:只调 API + 解析 + 返回强类型结果。
/// 业务状态(title/coverUrl 等 Rx)归 controller 层。
class PlaylistRepository extends GetxService {
  final NeteaseApi _api;

  PlaylistRepository(this._api);

  final PlaylistEventsController _events = Get.find<PlaylistEventsController>();

  /// 拉歌单元信息(标题/封面/描述 + source),null = API 失败或字段缺失。
  /// `subscribed` bool 在这里一次翻成 enum,调用方只读 [PlaylistSource]。
  Future<PlaylistMeta?> fetchMeta(String playlistId) async {
    try {
      final r = await apiCall(
        () => _api.callApi('playlist_detail', <Object?>[playlistId]),
        what: '拉歌单详情',
      );
      final playlist = r.body['playlist'];
      if (playlist is! Map) return null;
      final p = Map<String, dynamic>.from(playlist);
      return PlaylistMeta(
        name: (p['name'] ?? '').toString(),
        coverUrl: (p['coverImgUrl'] ?? '').toString(),
        description: (p['description'] ?? '').toString(),
        source: p['subscribed'] == true
            ? PlaylistSource.collected
            : PlaylistSource.created,
      );
    } on ApiException {
      return null;
    }
  }

  /// 拉歌单所有曲目,空列表 = API 失败或 songs 字段缺失。
  /// 用 track_all 而不是 detail.tracks —— 后者只返前 1000 首。
  Future<List<Song>> fetchTracks(String playlistId) async {
    try {
      final r = await apiCall(
        () => _api.callApi('playlist_track_all', <Object?>[playlistId]),
        what: '拉歌单曲目',
      );
      final songsList = r.body['songs'];
      if (songsList is! List) return [];
      return songsList
          .whereType<Map>()
          .map((m) => Song.fromNeteaseJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiException {
      return [];
    }
  }

  // 歌单写入
  //
  // status 一直是 200 即使业务失败(API 包了一层),所以**必须**看 body.code。

  /// 创建新歌单,返回新 id;业务 code != 200 或结构异常返回 null。
  /// 新 id 在 body['playlist']['id'],顶层 body['id'] 是冗余的同值副本。
  Future<String?> createPlaylist(String name) async {
    final MusicResponse r;
    try {
      r = await apiCall(
        () => _api.callApi('playlist_create', <Object?>[name]),
        what: '创建歌单',
      );
    } on ApiException {
      return null;
    }
    return _extractNewPlaylistId(r);
  }

  /// 把歌曲加入歌单。songIds 一次性 join(',') 提交;网易云单次上限 ~1000,
  /// 超出要由调用方分批 —— repository 不做静默截断。
  Future<bool> addTracks(String playlistId, List<String> songIds) async {
    if (songIds.isEmpty) return false;
    final tracks = songIds.join(',');
    final MusicResponse r;
    try {
      r = await apiCall(
        () => _api.callApi('playlist_tracks', <Object?>[
          'add',
          playlistId,
          tracks,
        ]),
        what: '添加歌曲到歌单',
      );
    } on ApiException catch (e) {
      // checkResponse 抛异常时 raw body 已装进 e.rawBody
      if (kDebugMode) {
        debugPrint(
          '[PlaylistRepository.addTracks] FAILED ApiException code=${e.code} '
          'message=${e.message}\n'
          'raw body: ${e.rawBody}\n'
          'params: playlistId=$playlistId tracks=$tracks',
        );
      }
      return false;
    }
    if (!_extractAddResult(r)) {
      if (kDebugMode) {
        debugPrint(
          '[PlaylistRepository.addTracks] FAILED raw body: ${r.body}\n'
          'params: playlistId=$playlistId tracks=$tracks',
        );
      }
      return false;
    }
    _events.applyDelta(playlistId, songIds.length);
    return true;
  }

  /// 从歌单删除歌曲。成功判定沿用 [addTracks](未真机校准)。
  Future<bool> removeTracks(String playlistId, List<String> songIds) async {
    if (songIds.isEmpty) return false;
    final tracks = songIds.join(',');
    final MusicResponse r;
    try {
      r = await apiCall(
        () => _api.callApi('playlist_tracks', <Object?>[
          'del',
          playlistId,
          tracks,
        ]),
        what: '从歌单删除歌曲',
      );
    } on ApiException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[PlaylistRepository.removeTracks] FAILED ApiException code=${e.code} '
          'message=${e.message}\n'
          'raw body: ${e.rawBody}\n'
          'params: playlistId=$playlistId tracks=$tracks',
        );
      }
      return false;
    }
    if (!_extractRemoveResult(r)) {
      if (kDebugMode) {
        debugPrint(
          '[PlaylistRepository.removeTracks] FAILED raw body: ${r.body}\n'
          'params: playlistId=$playlistId tracks=$tracks',
        );
      }
      return false;
    }
    _events.applyDelta(playlistId, -songIds.length);
    return true;
  }

  bool _extractRemoveResult(MusicResponse r) => _hasBusinessCode200(r);

  /// 新歌单 id 在 body['playlist']['id'],顶层 body['id'] 是冗余同值副本。
  String? _extractNewPlaylistId(MusicResponse r) {
    if (r.body['code'] != 200) return null;
    final playlist = r.body['playlist'];
    if (playlist is Map) {
      final id = playlist['id'];
      if (id is int) return id.toString();
      if (id is String) return id;
    }
    // 顶层冗余 id
    final top = r.body['id'];
    if (top is int) return top.toString();
    if (top is String) return top;
    return null;
  }

  bool _extractAddResult(MusicResponse r) => _hasBusinessCode200(r);

  /// 删除歌单(只能删自建的,收藏的只能取消订阅 —— 上层 toggleFavorite)。
  /// 成功判定未真机校准,路径不对就改 [_extractDeleteResult]。
  Future<bool> deletePlaylist(String playlistId) async {
    final MusicResponse r;
    try {
      r = await apiCall(
        () => _api.callApi('playlist_delete', <Object?>[playlistId]),
        what: '删除歌单',
      );
    } on ApiException {
      return false;
    }
    final ok = _extractDeleteResult(r);
    // 歌单已不存在,本地不再需要 offset
    if (ok) _events.resetDelta(playlistId);
    return ok;
  }

  bool _extractDeleteResult(MusicResponse r) => r.body['code'] == 200;

  /// `/playlist/tracks` 的 code **在嵌套的 `r.body['body']['code']`**,不在
  /// 顶层(其它端点如 playlist_create 在顶层)。所以两层都要查。
  bool _hasBusinessCode200(MusicResponse r) {
    if (r.body['code'] == 200) return true;
    final nested = r.body['body'];
    return nested is Map && nested['code'] == 200;
  }
}
