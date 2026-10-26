import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/app/data/models/download_task_view.dart';
import 'package:oceanus/app/data/models/song.dart';

void main() {
  const song = Song(
    id: '1',
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    coverUrl: '',
    duration: Duration(seconds: 10),
  );

  DownloadTaskView task({
    String taskId = 'task-1',
    DownloadStatus status = DownloadStatus.enqueued,
    double progress = 0,
    String? errorMessage,
    String? savedPath,
  }) {
    return DownloadTaskView(
      taskId: taskId,
      songId: song.id,
      song: song,
      status: status,
      progress: progress,
      errorMessage: errorMessage,
      savedPath: savedPath,
    );
  }

  group('DownloadTaskView.copyWith', () {
    test('只覆盖传入的字段', () {
      final base = task(
        status: DownloadStatus.running,
        progress: 0.5,
        errorMessage: 'boom',
      );

      final updated = base.copyWith(status: DownloadStatus.complete);

      expect(updated.status, DownloadStatus.complete);
      expect(updated.progress, 0.5);
      expect(updated.errorMessage, 'boom');
      expect(updated.taskId, 'task-1');
    });

    test('clearError 清掉错误信息', () {
      final base = task(errorMessage: 'boom');

      expect(base.copyWith(clearError: true).errorMessage, isNull);
    });

    test('clearSavedPath 清掉保存路径', () {
      final base = task(savedPath: '/tmp/a.mp3');

      expect(base.copyWith(clearSavedPath: true).savedPath, isNull);
    });

    test('songId / song 是跨重启的稳定标识,不被 copyWith 改写', () {
      final base = task();

      final updated = base.copyWith(
        taskId: 'task-2',
        status: DownloadStatus.failed,
      );

      expect(updated.taskId, 'task-2');
      expect(updated.songId, song.id);
      expect(updated.song, same(song));
    });

    test('progress 默认 0', () {
      final view = DownloadTaskView(
        taskId: 't',
        songId: '1',
        song: song,
        status: DownloadStatus.enqueued,
      );

      expect(view.progress, 0);
      expect(view.errorMessage, isNull);
      expect(view.savedPath, isNull);
    });
  });
}
