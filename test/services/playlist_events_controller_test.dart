import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/services/playlist_events_controller.dart';

void main() {
  late PlaylistEventsController controller;

  setUp(() => controller = PlaylistEventsController());
  tearDown(() => controller.onClose());

  group('deltaFor', () {
    test('没有记录时是 0', () {
      expect(controller.deltaFor('123'), 0);
    });

    test('applyDelta 后能读到累加值', () {
      controller.applyDelta('123', 2);

      expect(controller.deltaFor('123'), 2);
    });
  });

  group('applyDelta', () {
    test('多次调用是累加而不是覆盖', () {
      controller.applyDelta('123', 1);
      controller.applyDelta('123', 1);
      controller.applyDelta('123', 1);

      expect(controller.deltaFor('123'), 3);
    });

    test('负数表示减歌', () {
      controller.applyDelta('123', 5);
      controller.applyDelta('123', -2);

      expect(controller.deltaFor('123'), 3);
    });

    test('n=0 时什么都不做(不写 0,也不发事件)', () async {
      final events = <PlaylistTrackChangedEvent>[];
      final sub = controller.onTrackChanged.listen(events.add);

      controller.applyDelta('123', 0);
      await Future<void>.delayed(Duration.zero);

      expect(controller.deltaFor('123'), 0);
      expect(events, isEmpty);
      await sub.cancel();
    });

    test('不同歌单各自记账', () {
      controller.applyDelta('a', 1);
      controller.applyDelta('b', 2);

      expect(controller.deltaFor('a'), 1);
      expect(controller.deltaFor('b'), 2);
    });
  });

  group('resetDelta', () {
    test('把累加值清零', () {
      controller.applyDelta('123', 5);
      controller.resetDelta('123');

      expect(controller.deltaFor('123'), 0);
    });

    test('清零后继续累加', () {
      controller.applyDelta('123', 5);
      controller.resetDelta('123');
      controller.applyDelta('123', 2);

      expect(controller.deltaFor('123'), 2);
    });
  });

  group('onTrackChanged', () {
    test('每次 applyDelta 发一条事件,带 playlistId 和 delta', () async {
      final events = <PlaylistTrackChangedEvent>[];
      final sub = controller.onTrackChanged.listen(events.add);

      controller.applyDelta('123', 2);
      controller.applyDelta('123', -1);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events[0].playlistId, '123');
      expect(events[0].delta, 2);
      expect(events[1].delta, -1);
      await sub.cancel();
    });

    test('resetDelta 不发事件', () async {
      final events = <PlaylistTrackChangedEvent>[];
      final sub = controller.onTrackChanged.listen(events.add);

      controller.resetDelta('123');
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });
  });
}
