import 'package:flutter/material.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:get/get.dart';

import 'LyricsController.dart';

/// 可滚动歌词栏:由 [flutter_lyric] 提供渲染 + 高亮 + 自动滚动 + 触摸 seek
/// 字号 / 颜色全部走主题,在 [LyricPresets.aurora] 基础上 copyWith 覆盖外观。
///
/// lyricController 来自 [LyricsController] (main.dart 注册, permanent: true,
/// 跟 PlayerController 同生命周期), 保证:
/// - Lyrics widget 任何时候 mount 都能从 lyricNotifier.value 拿到当前 lyric
///   (修复"首次播放 lyrics 不加载": 老架构 lyricController 跟 PlayerController
///   同生命周期但 fetchLyric 是 await 的, LyricView mount 时 listener 注册晚于
///   lyricNotifier emit, 第一次 build 后 layout 算不出来 → 不渲染)
/// - 跨 PlayerController 实例共享同一份 lyric (将来多 PlayerPage 也安全)
class Lyrics extends StatelessWidget {
  const Lyrics({super.key});

  @override
  Widget build(BuildContext context) {
    final lyrics = Get.find<LyricsController>();
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return LyricView(
      controller: lyrics.lyricController,
      preset: LyricPresets.aurora.copyWith(
        textStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        activeTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.secondary,
          fontWeight: FontWeight.bold,
        ),
        translationTextStyle: textTheme.titleMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        activeTranslationTextStyle: textTheme.titleMedium?.copyWith(
          color: scheme.primary,
        ),
        highlight: LyricHighlight.solid(scheme.primary),
        textAlign: TextAlign.center,
        contentAlignment: LyricContentAlignment.center,
      ),
      onLineTap: (details) => lyrics.seekToLyric(details.seekPosition),
    );
  }
}

class LyricsBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<LyricsController>(() => LyricsController());
  }
}
