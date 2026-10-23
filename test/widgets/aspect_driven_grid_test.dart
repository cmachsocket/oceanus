import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/widgets/aspect_driven_grid.dart';

void main() {
  /// 把网格塞进一个固定尺寸的盒子里,好算出列数。
  Widget wrap({
    required double width,
    required double height,
    required Widget child,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );
  }

  Widget grid({int itemCount = 6}) {
    return AspectDrivenGrid(
      itemCount: itemCount,
      itemBuilder: (context, index) => const SizedBox.shrink(),
    );
  }

  SliverGridDelegateWithFixedCrossAxisCount delegateOf(WidgetTester tester) {
    final grid = tester.widget<GridView>(find.byType(GridView));
    return grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  }

  group('AspectDrivenGrid', () {
    testWidgets('列数由容器的宽高比决定', (tester) async {
      // 宽高比 2.0 → 基准 2 列 × 2.0 = 4 列
      await tester.pumpWidget(wrap(width: 400, height: 200, child: grid()));

      expect(delegateOf(tester).crossAxisCount, 4);
    });

    testWidgets('窄容器至少 1 列', (tester) async {
      // 宽高比 0.5 → 2 × 0.5 = 1 列
      await tester.pumpWidget(wrap(width: 200, height: 400, child: grid()));

      expect(delegateOf(tester).crossAxisCount, 1);
    });

    testWidgets('宽容器最多 6 列', (tester) async {
      // 宽高比 10 → 2 × 10 = 20 → 截到上限 6
      await tester.pumpWidget(wrap(width: 1000, height: 100, child: grid()));

      expect(delegateOf(tester).crossAxisCount, 6);
    });

    testWidgets('间距 = 列宽 × gapRatio', (tester) async {
      await tester.pumpWidget(wrap(width: 400, height: 200, child: grid()));

      final delegate = delegateOf(tester);
      expect(delegate.mainAxisSpacing, closeTo(400 / 4 * 0.04, 1e-9));
      expect(delegate.crossAxisSpacing, closeTo(400 / 4 * 0.04, 1e-9));
    });

    testWidgets('item 比例透传给 delegate', (tester) async {
      await tester.pumpWidget(
        wrap(
          width: 400,
          height: 200,
          child: AspectDrivenGrid(
            itemCount: 3,
            itemBuilder: (context, index) => const SizedBox.shrink(),
            childAspectRatio: 1.5,
          ),
        ),
      );

      expect(delegateOf(tester).childAspectRatio, 1.5);
    });

    testWidgets('按 itemCount 渲染对应数量的 item', (tester) async {
      await tester.pumpWidget(
        wrap(
          width: 400,
          height: 200,
          child: AspectDrivenGrid(
            itemCount: 3,
            itemBuilder: (context, index) => Text('item-$index'),
          ),
        ),
      );

      expect(find.text('item-0'), findsOneWidget);
      expect(find.text('item-2'), findsOneWidget);
      expect(find.text('item-3'), findsNothing);
    });
  });

  group('MasonryAspectDrivenGrid', () {
    testWidgets('列数同样由宽高比决定', (tester) async {
      await tester.pumpWidget(
        wrap(
          width: 400,
          height: 200,
          child: MasonryAspectDrivenGrid(
            itemCount: 4,
            itemBuilder: (context, index) => const SizedBox.shrink(),
          ),
        ),
      );

      final masonry = tester.widget<MasonryGridView>(
        find.byType(MasonryGridView),
      );
      final delegate =
          masonry.gridDelegate
              as SliverSimpleGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
    });
  });
}
