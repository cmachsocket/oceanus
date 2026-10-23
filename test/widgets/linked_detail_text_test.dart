import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/models/song.dart';
import 'package:oceanus/widgets/linked_detail_text.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  const song = Song(
    id: '1',
    title: '晴天',
    artist: '周杰伦',
    artistId: '6452',
    album: '叶惠美',
    albumId: '186016',
    coverUrl: '',
    duration: Duration(seconds: 10),
  );

  group('有 id', () {
    testWidgets('艺人 / 专辑都是可点的按钮', (tester) async {
      await tester.pumpWidget(wrap(const LinkedDetailText(song: song)));

      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.text('叶惠美'), findsOneWidget);
      expect(find.byType(TextButton), findsNWidgets(2));
    });

    testWidgets('中间的连接符也在', (tester) async {
      await tester.pumpWidget(wrap(const LinkedDetailText(song: song)));

      expect(find.text('-'), findsOneWidget);
    });
  });

  group('没有 id', () {
    testWidgets('艺人缺 id 时降级成只读文本,专辑仍可点', (tester) async {
      const noArtistId = Song(
        id: '1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        albumId: '186016',
        coverUrl: '',
        duration: Duration(seconds: 10),
      );

      await tester.pumpWidget(wrap(const LinkedDetailText(song: noArtistId)));

      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
    });

    testWidgets('艺人名为空时显示"未知艺人"', (tester) async {
      const anonymous = Song(
        id: '1',
        title: '晴天',
        artist: '',
        album: '叶惠美',
        albumId: '186016',
        coverUrl: '',
        duration: Duration(seconds: 10),
      );

      await tester.pumpWidget(wrap(const LinkedDetailText(song: anonymous)));

      expect(find.text('未知艺人'), findsOneWidget);
    });

    testWidgets('专辑名为空时显示"未知专辑"', (tester) async {
      const anonymous = Song(
        id: '1',
        title: '晴天',
        artist: '周杰伦',
        artistId: '6452',
        album: '',
        coverUrl: '',
        duration: Duration(seconds: 10),
      );

      await tester.pumpWidget(wrap(const LinkedDetailText(song: anonymous)));

      expect(find.text('未知专辑'), findsOneWidget);
    });

    testWidgets('两个 id 都缺时没有按钮', (tester) async {
      const bare = Song(
        id: '1',
        title: '晴天',
        artist: '',
        album: '',
        coverUrl: '',
        duration: Duration(seconds: 10),
      );

      await tester.pumpWidget(wrap(const LinkedDetailText(song: bare)));

      expect(find.byType(TextButton), findsNothing);
      expect(find.text('未知艺人'), findsOneWidget);
      expect(find.text('未知专辑'), findsOneWidget);
    });
  });
}
