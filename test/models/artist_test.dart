import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/app/data/models/artist.dart';

void main() {
  group('Artist.fromNeteaseJson', () {
    test('解析完整字段', () {
      final artist = Artist.fromNeteaseJson(<String, dynamic>{
        'id': 6452,
        'name': '周杰伦',
        'briefDesc': '华语流行音乐天王',
        'picUrl': 'https://example.com/jay.jpg',
        'musicSize': 300,
        'albumSize': 20,
        'fans': 100000,
      });

      expect(artist.id, '6452');
      expect(artist.name, '周杰伦');
      expect(artist.bio, '华语流行音乐天王');
      expect(artist.photoUrl, 'https://example.com/jay.jpg');
      expect(artist.songCount, 300);
      expect(artist.albumCount, 20);
      expect(artist.fanCount, 100000);
    });

    test('desc 是 briefDesc 的备选', () {
      final artist = Artist.fromNeteaseJson(<String, dynamic>{
        'id': 1,
        'desc': '备用简介',
      });

      expect(artist.bio, '备用简介');
    });

    test('缺字段时计数归零,文本为空', () {
      final artist = Artist.fromNeteaseJson(<String, dynamic>{'id': 9});

      expect(artist.id, '9');
      expect(artist.name, '');
      expect(artist.bio, '');
      expect(artist.photoUrl, '');
      expect(artist.songCount, 0);
      expect(artist.albumCount, 0);
      expect(artist.fanCount, 0);
    });

    test('计数字段类型不对时归零而不是崩', () {
      final artist = Artist.fromNeteaseJson(<String, dynamic>{
        'id': 1,
        'musicSize': 'many',
      });

      expect(artist.songCount, 0);
    });
  });
}
