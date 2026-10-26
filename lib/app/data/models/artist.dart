/// 艺人模型
class Artist {
  final String id;
  final String name;
  final String bio;
  final String photoUrl;
  final int songCount;
  final int albumCount;
  final int fanCount;

  const Artist({
    required this.id,
    required this.name,
    required this.bio,
    required this.photoUrl,
    this.songCount = 0,
    this.albumCount = 0,
    this.fanCount = 0,
  });

  /// 从 `/artists` / `/artist/detail` / `/artist/desc` 的 JSON 解析。
  /// 不同端点字段不齐(如 `/artist/album` 的 summary 没有 fans),缺一律给 0。
  factory Artist.fromNeteaseJson(Map<String, dynamic> json) {
    return Artist(
      id: json['id'].toString(),
      name: (json['name'] ?? '').toString(),
      bio: (json['briefDesc'] ?? json['desc'] ?? '').toString(),
      photoUrl: (json['picUrl'] ?? '').toString(),
      songCount: json['musicSize'] is int ? json['musicSize'] as int : 0,
      albumCount: json['albumSize'] is int ? json['albumSize'] as int : 0,
      fanCount: json['fans'] is int ? json['fans'] as int : 0,
    );
  }
}
