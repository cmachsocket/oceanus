// 一张"纯比例驱动"的网格。零硬编码像素。
//   - 列数 = 容器宽高比决定
//   - 间距 = 列宽 × gapRatio
//   - item 宽高比 = 调用方直接传 childAspectRatio
//
// 所有数值参数（baseColumns / baseRatio / gapRatio / childAspectRatio）都是相对量，不是像素。

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// 三个 grid widget 的默认参数集中放这里
///
/// - 三个 constructor (AspectDrivenGrid / SliverAspectDrivenGrid / MasonryAspectDrivenGrid)
///   共用这套默认值,避免改一处忘改另两处造成不一致。
/// - `private` (下划线开头) 仅本文件内部用,外部不应该手动改。
class _GridDefaults {
  /// 基准宽高比下的列数（默认 2）
  static const int baseColumns = 2;

  /// 基准宽高比（默认 1.0 = 1:1）
  static const double baseRatio = 1.0;

  /// 间距 = 列宽 × 此比例（0.02~0.06 区间）
  static const double gapRatio = 0.04;

  /// item 自身的宽/高比（默认 1.0 = 永远方）
  static const double childAspectRatio = 1.0;

  /// 列数限位
  static const int minColumns = 1;
  static const int maxColumns = 6;
}

/// 1. 标准版（等高 item，列数 / 间距 / item 比例全部派生）
class AspectDrivenGrid extends StatelessWidget {
  const AspectDrivenGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.baseColumns = _GridDefaults.baseColumns,
    this.baseRatio = _GridDefaults.baseRatio,
    this.gapRatio = _GridDefaults.gapRatio,
    this.childAspectRatio = _GridDefaults.childAspectRatio,
    this.minColumns = _GridDefaults.minColumns,
    this.maxColumns = _GridDefaults.maxColumns,
    this.padding = EdgeInsets.zero,
    this.scrollPhysics,
    this.shrinkWrap = false,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 参数语义与默认值见 [_GridDefaults]
  final int baseColumns;
  final double baseRatio;
  final double gapRatio;
  final double childAspectRatio;
  final int minColumns;
  final int maxColumns;

  final EdgeInsetsGeometry padding;
  final ScrollPhysics? scrollPhysics;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        assert(
          c.hasBoundedWidth && c.hasBoundedHeight,
          'AspectDrivenGrid 需要父容器在两个轴上都有界 '
          '(例如 Scaffold body / Column + Expanded)，'
          '不要直接放进 SingleChildScrollView 或 ListView。',
        );
        final ratio = c.maxWidth / c.maxHeight;
        final cols = (baseColumns * (ratio / baseRatio))
            .clamp(minColumns, maxColumns)
            .round();
        final gap = (c.maxWidth / cols) * gapRatio;

        return GridView.builder(
          padding: padding,
          physics: scrollPhysics,
          shrinkWrap: shrinkWrap,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

/// 2. Sliver 版 —— 嵌进 CustomScrollView 用
/// 用 viewport 的宽高算 ratio（不是 sliver 自身的内容高度）
class SliverAspectDrivenGrid extends StatelessWidget {
  const SliverAspectDrivenGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.baseColumns = _GridDefaults.baseColumns,
    this.baseRatio = _GridDefaults.baseRatio,
    this.gapRatio = _GridDefaults.gapRatio,
    this.childAspectRatio = _GridDefaults.childAspectRatio,
    this.minColumns = _GridDefaults.minColumns,
    this.maxColumns = _GridDefaults.maxColumns,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 基准宽高比下的列数;基准宽高比;间距 = 列宽 × gapRatio;
  /// item 自身宽/高比(见 [_GridDefaults])。全部是相对量,不是像素。
  final int baseColumns;
  final double baseRatio;
  final double gapRatio;
  final double childAspectRatio;

  /// 列数限位
  final int minColumns;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, c) {
        // 可视宽高 = viewport 宽 × viewport 高(始终有界)
        final ratio = c.crossAxisExtent / c.viewportMainAxisExtent;
        final cols = (baseColumns * (ratio / baseRatio))
            .clamp(minColumns, maxColumns)
            .round();
        final gap = (c.crossAxisExtent / cols) * gapRatio;

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: childAspectRatio,
          ),
          delegate: SliverChildBuilderDelegate(
            itemBuilder,
            childCount: itemCount,
          ),
        );
      },
    );
  }
}

/// 3. Pinterest 瀑布流版 —— item 高度不一时使用
/// 需要 pubspec.yaml: flutter_staggered_grid_view
class MasonryAspectDrivenGrid extends StatelessWidget {
  const MasonryAspectDrivenGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.baseColumns = _GridDefaults.baseColumns,
    this.baseRatio = _GridDefaults.baseRatio,
    this.gapRatio = _GridDefaults.gapRatio,
    this.minColumns = _GridDefaults.minColumns,
    this.maxColumns = _GridDefaults.maxColumns,
    this.padding = EdgeInsets.zero,
    this.scrollPhysics,
    this.shrinkWrap = false,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int baseColumns;
  final double baseRatio;
  final double gapRatio;
  final int minColumns;
  final int maxColumns;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? scrollPhysics;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        assert(
          c.hasBoundedWidth && c.hasBoundedHeight,
          'MasonryAspectDrivenGrid 需要父容器在两个轴上都有界',
        );
        final ratio = c.maxWidth / c.maxHeight;
        final cols = (baseColumns * (ratio / baseRatio))
            .clamp(minColumns, maxColumns)
            .round();
        final gap = (c.maxWidth / cols) * gapRatio;

        return MasonryGridView.count(
          padding: padding,
          physics: scrollPhysics,
          shrinkWrap: shrinkWrap,
          crossAxisCount: cols,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
