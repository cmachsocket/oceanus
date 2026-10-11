/// 专辑 / EP / 单曲 模型
///
/// 字段从 [netease_cloud_music_api.artist_album] / [album] / [album_detail] 解析
enum AlbumType { album, ep, single, compilation }

extension AlbumTypeLabel on AlbumType {
  String get label => switch (this) {
    AlbumType.album => '专辑',
    AlbumType.ep => 'EP',
    AlbumType.single => '单曲',
    AlbumType.compilation => '合辑',
  };
}

class Album {
  final String id;
  final String name;
  final String artist;
  final String coverUrl;
  final int songCount;
  final DateTime releaseDate;
  final AlbumType type;

  const Album({
    required this.id,
    required this.name,
    required this.artist,
    required this.coverUrl,
    required this.songCount,
    required this.releaseDate,
    required this.type,
  });

  /// 从网易云 /album 或 /artist/album 返回的 JSON 解析。
  /// `artists` 取第一个 name;`type` 是 'Album' / 'Single' / 'EP' / 'Compilation'
  factory Album.fromNeteaseJson(Map<String, dynamic> json) {
    final artists = (json['artists'] as List?) ?? const [];
    final firstArtist = artists.isNotEmpty
        ? Map<String, dynamic>.from(artists.first as Map)
        : null;
    final size = json['size'] is int ? json['size'] as int : 0;
    final publishTime = json['publishTime'] is int
        ? json['publishTime'] as int
        : 0;
    final typeStr = (json['type'] ?? 'Album').toString().toLowerCase();
    final type = switch (typeStr) {
      'single' => AlbumType.single,
      'ep' => AlbumType.ep,
      'compilation' => AlbumType.compilation,
      _ => AlbumType.album,
    };
    return Album(
      id: json['id'].toString(),
      name: (json['name'] ?? '').toString(),
      artist: (firstArtist?['name'] ?? '').toString(),
      coverUrl: (json['picUrl'] ?? '').toString(),
      songCount: size,
      releaseDate: DateTime.fromMillisecondsSinceEpoch(publishTime),
      type: type,
    );
  }
}
