import 'package:flutter/material.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:get/get.dart';
import 'player_controller.dart';
import '../models/default.dart';

class MusicProgressBar extends StatelessWidget {
  const MusicProgressBar({
    super.key,
    this.timeLabelLocation = TimeLabelLocation.below,
  });
  final TimeLabelLocation timeLabelLocation;
  static const baseBarAplha = 0.3;
  static const bufferedBarAlpha = 0.3;
  static const thumbGlowColorAlpha = 0.4;
  @override
  Widget build(BuildContext context) {
    final controller = Get.find<PlayerController>(
      tag: DefaultValues.playerControllerTag,
    );
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Obx(
      () => ProgressBar(
        timeLabelLocation: timeLabelLocation,
        progress: controller.position.value,
        buffered: controller.buffered.value,
        total: controller.duration.value,
        onSeek: controller.seek,
        progressBarColor: scheme.primary,
        baseBarColor: scheme.onSurface.withValues(alpha: baseBarAplha),
        bufferedBarColor: scheme.tertiary.withValues(alpha: bufferedBarAlpha),
        thumbColor: scheme.secondary,
        thumbGlowColor: scheme.secondary.withValues(alpha: thumbGlowColorAlpha),
        timeLabelTextStyle: textTheme.bodySmall,
      ),
    );
  }
}
