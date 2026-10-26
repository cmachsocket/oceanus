import 'package:meta/meta.dart';
import 'package:flutter/material.dart';

@sealed
class DefaultValues {
  DefaultValues._();
  static const double landscopeGridChildAspectRatio = 0.75;
  static const double portraitGridChildAspectRatio = 0.70;
  static const int gridMinColumns = 2;
  static const double landscopeArtistGridChildAspectRatio = 0.78;
  static const double portraitArtistGridChildAspectRatio = 0.70;
  static const double squardRatio = 1.0;
  static const int shellNavigatorId = 0;
  static const int songListBodyNavigatorId = 1;
  static const String searchSongListId = '-1';
  static const String playerControllerTag = 'PlayerController_v1';
  static const String playlistControllerTag = 'PlayListController_v1';
  // 唯一的硬编码size
  static const EdgeInsets onlyZero = EdgeInsets.only(left: 0, right: 0);
}
