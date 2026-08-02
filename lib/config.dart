import 'package:lichess_checker/types.dart';

extension type AppConfig(Map<String, Object?> _map) {
  String? get apiKey => _map['apiKey'] as String?;
  int? get maxGames => _map['maxGames'] as int?;

  Map<String, List<DesiredGame>> get games {
    var gamesMap = _map['games'] as Map<String, Object?>;
    return {
      for (var MapEntry(key: opponent, value: gamesList) in gamesMap.entries)
        opponent: (gamesList as List)
            .cast<Map<String, Object?>>()
            .map(DesiredGame.new)
            .toList(),
    };
  }
}

extension type DesiredGame(Map<String, Object?> _map) {
  Variant get variant => Variant.parse(_map['variant'] as String);
  Color get color => Color.parse(_map['color'] as String);
  bool get priority => _map['priority'] as bool? ?? false;
}
