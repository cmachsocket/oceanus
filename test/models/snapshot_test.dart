import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:oceanus/models/snapshot.dart';
import 'package:oceanus/models/song.dart';

PlaybackSnapshot _snapshot({
  bool isPlaying = false,
  Duration position = Duration.zero,
  Duration bufferedPosition = Duration.zero,
  Song? currentSong,
  List<MediaItem> queue = const [],
  int currentIndex = -1,
  PlayOrder playOrder = PlayOrder.sequential,
  bool isCurrentSongLiked = false,
}) {
  return PlaybackSnapshot(
    isPlaying: isPlaying,
    processingState: ProcessingState.idle,
    position: position,
    bufferedPosition: bufferedPosition,
    currentSong: currentSong,
    queue: queue,
    currentIndex: currentIndex,
    playOrder: playOrder,
    isCurrentSongLiked: isCurrentSongLiked,
  );
}

void main() {
  const song = Song(
    id: '1',
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    coverUrl: '',
    duration: Duration(seconds: 10),
  );

  group('PlaybackSnapshot.copyWith', () {
    test('未传的字段保持原值', () {
      final base = _snapshot(
        isPlaying: true,
        position: const Duration(seconds: 30),
        currentSong: song,
        currentIndex: 3,
        playOrder: PlayOrder.shuffle,
        isCurrentSongLiked: true,
      );

      final updated = base.copyWith(isPlaying: false);

      expect(updated.isPlaying, false);
      expect(updated.position, const Duration(seconds: 30));
      expect(updated.currentSong, song);
      expect(updated.currentIndex, 3);
      expect(updated.playOrder, PlayOrder.shuffle);
      expect(updated.isCurrentSongLiked, true);
    });

    test('clearCurrentSong 把 currentSong 清成 null', () {
      final base = _snapshot(currentSong: song);

      expect(base.copyWith(clearCurrentSong: true).currentSong, isNull);
    });

    test('currentSong 传 null 时保留原值(要显式 clear)', () {
      final base = _snapshot(currentSong: song);

      expect(base.copyWith().currentSong, song);
      expect(base.copyWith(currentSong: null).currentSong, song);
    });

    test('queue / currentIndex / playOrder 可覆盖', () {
      final base = _snapshot();
      final updated = base.copyWith(
        queue: const <MediaItem>[],
        currentIndex: 7,
        playOrder: PlayOrder.repeatOne,
      );

      expect(updated.currentIndex, 7);
      expect(updated.playOrder, PlayOrder.repeatOne);
    });
  });
}
