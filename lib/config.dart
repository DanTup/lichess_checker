import 'package:lichess_checker/types.dart';

extension type AppConfig(Map<String, Object?> _map) {
  String? get apiKey => _map['apiKey'] as String?;
  int? maxGamesForOpponent(String opponent) {
    var maxGames = _map['maxGames'];
    if (maxGames is int) {
      return maxGames;
    }
    if (maxGames is Map<String, Object?>) {
      return maxGames[opponent] as int?;
    }
    return null;
  }

  Map<String, List<(Variant variant, Color color, bool priority)>> get games {
    var gamesMap = _map['games'] as Map<String, Object?>;
    return {
      for (var MapEntry(key: opponent, value: gamesList) in gamesMap.entries)
        opponent: (gamesList as List)
            .cast<Map<String, Object?>>()
            .map(
              (game) => (
                Variant.parse(game['variant'] as String),
                Color.parse(game['color'] as String),
                game['priority'] as bool? ?? false,
              ),
            )
            .toList(),
    };
  }
}
