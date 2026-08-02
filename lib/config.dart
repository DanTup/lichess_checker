import 'package:lichess_checker/types.dart';

extension type AppConfig(Map<String, Object?> _map) {
  String? get apiKey => _map['apiKey'] as String?;

  Map<String, OpponentConfig> get games {
    var gamesMap = (_map['games'] as Map<String, Object?>)
        .cast<String, Map<String, Object?>>();
    return {
      for (var MapEntry(key: opponent, value: config) in gamesMap.entries)
        opponent: OpponentConfig(config),
    };
  }
}

extension type OpponentConfig(Map<String, Object?> _map) {
  int get maxGames => (_map['maxGames'] as int?) ?? 999;

  List<DesiredGame> get variants {
    return (_map['variants'] as List)
        .cast<Map<String, Object?>>()
        .map(DesiredGame.new)
        .toList();
  }
}

extension type DesiredGame(Map<String, Object?> _map) {
  Variant get variant => Variant.parse(_map['variant'] as String);
  Color get color => Color.parse(_map['color'] as String);
  bool get priority => _map['priority'] as bool? ?? false;
}
