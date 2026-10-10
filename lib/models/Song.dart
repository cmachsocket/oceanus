import 'package:audio_service/audio_service.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final String? artistId;
  final String album;
  final String? albumId;
  final String coverUrl;
  final Duration duration;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.artistId,
    required this.album,
    this.albumId,
    required this.coverUrl,
    required this.duration,
  });
  const Song.empty()
    : id = '',
      title = '',
      artist = '',
      artistId = null,
      album = '',
      albumId = null,
      coverUrl = '',
      duration = Duration.zero;

  String get durationLabel {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'artistId': artistId,
    'album': album,
    'albumId': albumId,
    'coverUrl': coverUrl,
    'duration': duration.inSeconds,
  };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    artistId: json['artistId'] as String?,
    album: json['album'] as String,
    albumId: json['albumId'] as String?,
    coverUrl: json['coverUrl'] as String,
    duration: Duration(seconds: json['duration'] as int),
  );

  /// 兼容网易云的两套 schema:`/search` 用 `artists`/`album`/`duration`,
  /// `/song/detail` 用简写的 `ar`/`al`/`dt`。歌手和专辑都只取第一个。
  factory Song.fromNeteaseJson(Map<String, dynamic> json) {
    final arList = json['ar'] ?? json['artists'];
    final artists = arList is List ? arList : const [];
    final firstArtist = artists.isNotEmpty
        ? Map<String, dynamic>.from(artists.first as Map)
        : null;
    final albumRaw = json['al'] ?? json['album'];
    final albumMap = albumRaw is Map
        ? Map<String, dynamic>.from(albumRaw)
        : null;
    // dt 和 duration 都是毫秒
    final dt = json['dt'] is int
        ? json['dt'] as int
        : (json['duration'] is int ? json['duration'] as int : 0);
    return Song(
      id: json['id'].toString(),
      title: (json['name'] ?? '').toString(),
      artist: (firstArtist?['name'] ?? '').toString(),
      artistId: firstArtist?['id']?.toString(),
      album: (albumMap?['name'] ?? '').toString(),
      albumId: albumMap?['id']?.toString(),
      coverUrl: (albumMap?['picUrl'] ?? '').toString(),
      duration: Duration(milliseconds: dt),
    );
  }

  /// Song -> MediaItem。业务层留 [Song],只在接入 audio_service(通知/锁屏/队列)
  /// 时转换。
  ///
  /// [duration] 要调用方传:mediaItem 上要的是播放器实时时长,而
  /// [Song.duration] 是静态元数据,两者语义不同。
  MediaItem toMediaItem({Duration? duration, Map<String, String>? artHeaders}) {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      artUri: coverUrl.isEmpty ? null : Uri.tryParse(coverUrl),
      artHeaders: artHeaders,
    );
  }
}
