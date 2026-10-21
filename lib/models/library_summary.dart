/// 首页 / 我的页 展示用的轻量摘要模型。
library;

/// 歌单来源。`/user/playlist` 用 bool `subscribed` 区分自建 vs 收藏,
/// 换成 enum 后语义自解释,switch 有 exhaustiveness 检查,真值转换集中在
/// fromNeteaseJson。
enum PlaylistSource {
  created, // 我创建的(subscribed == false)
  collected, // 我收藏/订阅的(subscribed == true)
  /// `/album?id=X` 走另一条接口,`playlistId` 以 `album-` 前缀区分
  album,

  artist,

  /// 纯粹的列表
  pure,
}

/// 首页推荐歌单卡片。
class PlaylistCard {
  final String id;
  final String name;
  final String picUrl;

  const PlaylistCard({
    required this.id,
    required this.name,
    required this.picUrl,
  });

  /// `/personalized` 的 result 数组元素。
  factory PlaylistCard.fromNeteaseJson(Map<String, dynamic> json) =>
      PlaylistCard(
        id: json['id'].toString(),
        name: (json['name'] ?? '').toString(),
        picUrl: (json['picUrl'] ?? '').toString(),
      );
}

/// 我的歌单摘要(Library tab 1)。红心按钮只对 [PlaylistSource.collected] 渲染 ——
/// 自建歌单没有"再收藏一次"的语义。
class PlaylistSummary {
  final String id;
  final String name;
  final String picUrl;
  final int trackCount;
  final PlaylistSource source;

  const PlaylistSummary({
    required this.id,
    required this.name,
    required this.picUrl,
    required this.trackCount,
    required this.source,
  });

  /// `/user/playlist` 的 playlist[] 元素。
  factory PlaylistSummary.fromNeteaseJson(Map<String, dynamic> json) =>
      PlaylistSummary(
        id: json['id'].toString(),
        name: (json['name'] ?? '').toString(),
        picUrl: (json['coverImgUrl'] ?? '').toString(),
        trackCount: (json['trackCount'] as int?) ?? 0,
        source: json['subscribed'] == true
            ? PlaylistSource.collected
            : PlaylistSource.created,
      );
}

/// 订阅专辑摘要(Library tab 2)。
class AlbumSummary {
  final String id;
  final String name;
  final String artist;
  final String picUrl;

  const AlbumSummary({
    required this.id,
    required this.name,
    required this.artist,
    required this.picUrl,
  });

  /// `/album/sublist` 的 data[] 元素。
  factory AlbumSummary.fromNeteaseJson(Map<String, dynamic> json) {
    final artists = (json['artists'] as List?) ?? const [];
    final firstArtist = artists.isNotEmpty
        ? Map<String, dynamic>.from(artists.first as Map)
        : null;
    return AlbumSummary(
      id: json['id'].toString(),
      name: (json['name'] ?? '').toString(),
      artist: (firstArtist?['name'] ?? '').toString(),
      picUrl: (json['picUrl'] ?? '').toString(),
    );
  }
}

/// 关注艺人摘要(Library tab 3)。
class ArtistSummary {
  final String id;
  final String name;
  final String picUrl;

  const ArtistSummary({
    required this.id,
    required this.name,
    required this.picUrl,
  });

  /// `/user/follow/mixed` 的 artistInfo 元素。
  factory ArtistSummary.fromNeteaseJson(Map<String, dynamic> json) =>
      ArtistSummary(
        id: json['id'].toString(),
        name: (json['name'] ?? '').toString(),
        picUrl: (json['picUrl'] ?? '').toString(),
      );
}
