import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/app/widgets/song_cover.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  group('SongCover', () {
    testWidgets('URL 为空时直接占位,不去请求网络', (tester) async {
      await tester.pumpWidget(wrap(const SongCover(url: '')));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNothing);
    });

    testWidgets('URL 为空时也不会因为解析失败而崩', (tester) async {
      await tester.pumpWidget(wrap(const SongCover(url: '')));

      expect(tester.takeException(), isNull);
    });
  });
}
