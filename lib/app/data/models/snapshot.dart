import 'package:audio_service/audio_service.dart';
import 'song.dart';
import 'package:just_audio/just_audio.dart';

/// 播放顺序。
enum PlayOrder { sequential, shuffle, repeatOne }

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.isPlaying,
    required this.processingState,
    required this.position,
    required this.bufferedPosition,
    required this.currentSong,
    required this.queue,
    required this.currentIndex,
    required this.playOrder,
    required this.isCurrentSongLiked,
  });

  final bool isPlaying;
  final ProcessingState processingState;
  final Duration position;
  final Duration bufferedPosition;

  final Song? currentSong;

  /// 完整队列(UI 用)
  final List<MediaItem> queue;

  /// 在 [queue] 里的索引;-1 = 没有当前播放
  final int currentIndex;

  final PlayOrder playOrder;
  final bool isCurrentSongLiked;

  PlaybackSnapshot copyWith({
    bool? isPlaying,
    ProcessingState? processingState,
    Duration? position,
    Duration? bufferedPosition,
    Song? currentSong,
    bool clearCurrentSong = false,
    List<MediaItem>? queue,
    int? currentIndex,
    PlayOrder? playOrder,
    bool? isCurrentSongLiked,
  }) {
    return PlaybackSnapshot(
      isPlaying: isPlaying ?? this.isPlaying,
      processingState: processingState ?? this.processingState,
      position: position ?? this.position,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      currentSong: clearCurrentSong ? null : (currentSong ?? this.currentSong),
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      playOrder: playOrder ?? this.playOrder,
      isCurrentSongLiked: isCurrentSongLiked ?? this.isCurrentSongLiked,
    );
  }
}
