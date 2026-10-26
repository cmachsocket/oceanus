import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/app/data/models/song.dart';

void main() {
  group('Song.fromNeteaseJson', () {
    test('解析 /search 的 schema(artists / album / duration)', () {
      final song = Song.fromNeteaseJson(<String, dynamic>{
        'id': 186016,
        'name': '晴天',
        'duration': 269000,
        'artists': <Map<String, dynamic>>[
          <String, dynamic>{'id': 6452, 'name': '周杰伦'},
        ],
        'album': <String, dynamic>{
          'id': 186016,
          'name': '叶惠美',
          'picUrl': 'https://example.com/cover.jpg',
        },
      });

      expect(song.id, '186016');
      expect(song.title, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.artistId, '6452');
      expect(song.album, '叶惠美');
      expect(song.albumId, '186016');
      expect(song.coverUrl, 'https://example.com/cover.jpg');
      expect(song.duration, const Duration(milliseconds: 269000));
    });

    test('解析 /song/detail 的简写 schema(ar / al / dt)', () {
      final song = Song.fromNeteaseJson(<String, dynamic>{
        'id': 186016,
        'name': '晴天',
        'dt': 269000,
        'ar': <Map<String, dynamic>>[
          <String, dynamic>{'id': 6452, 'name': '周杰伦'},
        ],
        'al': <String, dynamic>{
          'id': 186016,
          'name': '叶惠美',
          'picUrl': 'https://example.com/cover.jpg',
        },
      });

      expect(song.id, '186016');
      expect(song.artist, '周杰伦');
      expect(song.artistId, '6452');
      expect(song.album, '叶惠美');
      expect(song.albumId, '186016');
      expect(song.duration, const Duration(milliseconds: 269000));
    });

    test('只取第一个艺人 / 专辑', () {
      final song = Song.fromNeteaseJson(<String, dynamic>{
        'id': 1,
        'name': 'x',
        'artists': <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'A'},
          <String, dynamic>{'id': 2, 'name': 'B'},
        ],
      });

      expect(song.artist, 'A');
      expect(song.artistId, '1');
    });

    test('字段缺失时给空串 / 零时长,id 统一转字符串', () {
      final song = Song.fromNeteaseJson(<String, dynamic>{'id': 42});

      expect(song.id, '42');
      expect(song.title, '');
      expect(song.artist, '');
      expect(song.artistId, isNull);
      expect(song.album, '');
      expect(song.albumId, isNull);
      expect(song.coverUrl, '');
      expect(song.duration, Duration.zero);
    });

    test('artists 不是 List 时不当场崩', () {
      final song = Song.fromNeteaseJson(<String, dynamic>{
        'id': 1,
        'artists': 'not-a-list',
        'album': 123,
      });

      expect(song.artist, '');
      expect(song.album, '');
    });
  });

  group('Song JSON 往返', () {
    test('toJson / fromJson 保留全部字段', () {
      const song = Song(
        id: '1',
        title: '晴天',
        artist: '周杰伦',
        artistId: '6452',
        album: '叶惠美',
        albumId: '186016',
        coverUrl: 'https://example.com/cover.jpg',
        duration: Duration(minutes: 4, seconds: 29),
      );

      final restored = Song.fromJson(song.toJson());

      expect(restored.id, song.id);
      expect(restored.title, song.title);
      expect(restored.artist, song.artist);
      expect(restored.artistId, song.artistId);
      expect(restored.album, song.album);
      expect(restored.albumId, song.albumId);
      expect(restored.coverUrl, song.coverUrl);
      expect(restored.duration, song.duration);
    });

    test('toJson 把 duration 存成秒', () {
      const song = Song(
        id: '1',
        title: 't',
        artist: 'a',
        album: 'b',
        coverUrl: '',
        duration: Duration(seconds: 90),
      );

      expect(song.toJson()['duration'], 90);
    });

    test('Song.empty() 是空壳', () {
      const song = Song.empty();

      expect(song.id, '');
      expect(song.title, '');
      expect(song.duration, Duration.zero);
      expect(song.durationLabel, '0:00');
    });
  });

  group('Song.durationLabel', () {
    test('秒补零到两位', () {
      const song = Song(
        id: '1',
        title: 't',
        artist: 'a',
        album: 'b',
        coverUrl: '',
        duration: Duration(minutes: 3, seconds: 5),
      );

      expect(song.durationLabel, '3:05');
    });

    test('超过一小时也只显示分钟', () {
      const song = Song(
        id: '1',
        title: 't',
        artist: 'a',
        album: 'b',
        coverUrl: '',
        duration: Duration(hours: 1, minutes: 2, seconds: 3),
      );

      expect(song.durationLabel, '62:03');
    });
  });

  group('Song.toMediaItem', () {
    const song = Song(
      id: '1',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      coverUrl: 'https://example.com/cover.jpg',
      duration: Duration(seconds: 10),
    );

    test('字段一一映射', () {
      final item = song.toMediaItem();

      expect(item.id, '1');
      expect(item.title, '晴天');
      expect(item.artist, '周杰伦');
      expect(item.album, '叶惠美');
      expect(item.artUri.toString(), 'https://example.com/cover.jpg');
    });

    test('coverUrl 为空时 artUri 是 null', () {
      const empty = Song(
        id: '1',
        title: 't',
        artist: 'a',
        album: 'b',
        coverUrl: '',
        duration: Duration.zero,
      );

      expect(empty.toMediaItem().artUri, isNull);
    });

    test('传入的 duration 覆盖 Song.duration', () {
      final item = song.toMediaItem(duration: const Duration(seconds: 99));

      expect(item.duration, const Duration(seconds: 99));
    });

    test('artHeaders 透传', () {
      final item = song.toMediaItem(
        artHeaders: const <String, String>{'User-Agent': 'test'},
      );

      expect(item.artHeaders?['User-Agent'], 'test');
    });
  });
}
