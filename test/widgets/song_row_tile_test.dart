import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/modules/settings/controllers/settings_controller.dart';
import 'package:oceanus/app/modules/song_list/widgets/song_row_tile.dart';
import 'package:oceanus/app/data/models/song.dart';

import '../helpers/test_env.dart';

void main() {
  const song = Song(
    id: '1',
    title: '晴天',
    artist: '周杰伦',
    artistId: '6452',
    album: '叶惠美',
    albumId: '186016',
    coverUrl: '',
    duration: Duration(minutes: 3, seconds: 5),
  );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  setUp(() async {
    await initTestStorage();
    Get.put<SettingsController>(SettingsController(), permanent: true);
  });

  tearDown(teardownGetX);

  testWidgets('渲染歌名和艺人 - 专辑', (tester) async {
    await tester.pumpWidget(wrap(const SongRowTile(song: song)));

    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('叶惠美'), findsOneWidget);
  });

  testWidgets('没有 isLiked 回调时红心按钮不可点', (tester) async {
    await tester.pumpWidget(wrap(const SongRowTile(song: song)));

    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.favorite_border),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('给了 isLiked 回调时红心按钮可点', (tester) async {
    var tapped = false;
    // Obx 里要真的读到一个 Rx,否则 GetX 会报 "improper use"。
    final liked = false.obs;

    await tester.pumpWidget(
      wrap(
        SongRowTile(
          song: song,
          isLiked: () => liked.value,
          onToggleFavorite: () => tapped = true,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('isLiked 为 true 时换成实心红心', (tester) async {
    final liked = true.obs;

    await tester.pumpWidget(
      wrap(SongRowTile(song: song, isLiked: () => liked.value)),
    );

    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets('downloadMode 关闭时不显示下载按钮', (tester) async {
    await tester.pumpWidget(wrap(const SongRowTile(song: song)));

    expect(find.byIcon(Icons.download_outlined), findsNothing);
  });
}
