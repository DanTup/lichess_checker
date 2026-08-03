import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:lichess_checker/config.dart';
import 'package:lichess_checker/types.dart';

final random = Random();

Future<void> main(List<String> arguments) async {
  final configFile = File('config.json');
  if (!configFile.existsSync()) {
    stderr
      ..writeln('config.json not found!')
      ..writeln('')
      ..writeln(
        'Copy config.json.example to config.json and edit it to add your games.',
      );
    return;
  }

  final config = AppConfig(
    jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>,
  );

  final apiKey = config.apiKey ?? Platform.environment['LICHESS_KEY'];
  if (apiKey == null) {
    stderr
      ..writeln(
        'No API key found! Set "apiKey" in config.json or the LICHESS_KEY environment variable.',
      )
      ..writeln('')
      ..writeln(
        'Create a PAT at https://lichess.org/account/oauth/token/create with the following permissions:',
      )
      ..writeln('')
      ..writeln('- Read incoming challenges')
      ..writeln('- Send, accept and reject challenges');
    return;
  }

  // First, accept any inbound challenges. That way we'll have the existing
  // games to exclude from potential new challenges (and the correct count).
  final challenges = await getChallenges(apiKey);
  final allowedOpponents = config.games.keys.toSet();
  for (var challenge in challenges.inChallenges) {
    await acceptChallenge(challenge, allowedOpponents, apiKey);
  }

  // Track players with outbound challenges, as we can't raise any more.
  final playersWithOutboundChallenges = challenges.outChallenges
      .map((challenge) => challenge.destUser.username)
      .toSet();

  final desiredGames = config.games;
  final games = await getGames(apiKey);
  final playerGameType = <String, Map<Variant, List<Game>>>{};
  for (var game in games) {
    playerGameType
        .putIfAbsent(game.opponent.username, () => {})
        .putIfAbsent(game.variant, () => [])
        .add(game);
  }

  print('Open Games:');
  for (var MapEntry(key: opponent, value: opponentConfig)
      in desiredGames.entries) {
    var matchedVariants = <DesiredGame>[];
    var missingVariants = <DesiredGame>[];
    for (var game in opponentConfig.variants) {
      var DesiredGame(:color, :variant) = game;
      var theseGames =
          playerGameType[opponent]?[variant]
              ?.where(matchesGameColor(color))
              .toList() ??
          [];
      // Even though this is one desired game, we might have multiple existing
      // games that match, for ex. if we accidentally rematched on one with
      // an existing game/challenge.
      for (var game in theseGames) {
        print(
          [
            '',
            opponent.padRight(15),
            ('${variant.displayName} (${game.color.name})').padRight(25),
            (game.isMyTurn ? '** My Turn**' : '').padRight(15),
            'https://lichess.org/${game.gameId}'.padRight(50),
          ].join('  |  '),
        );
      }
      if (theseGames.isEmpty) {
        missingVariants.add(game);
        print(
          [
            '',
            opponent.padRight(15),
            ('${variant.displayName} (${color.name})').padRight(25),
            '** Missing! **'.padRight(15),
            ''.padRight(50),
          ].join('  |  '),
        );
      } else {
        matchedVariants.add(game);
      }
    }

    // If we have missing games, not an existing outbound challenge, and have
    // not hit max games for this player, we should send the next challenge.
    if (missingVariants.isNotEmpty &&
        !playersWithOutboundChallenges.contains(opponent) &&
        matchedVariants.length < opponentConfig.maxGames) {
      missingVariants.shuffle(random);

      var gameToChallenge = missingVariants.firstWhere(
        (game) => game.priority,
        orElse: () => missingVariants.first,
      );
      await sendChallenge(opponent, gameToChallenge, apiKey);
    }
  }
}

Future<void> sendChallenge(
  String opponent,
  DesiredGame game,
  String apiKey,
) async {
  var DesiredGame(:color, :variant) = game;
  var response = await http.post(
    Uri.parse('https://lichess.org/api/challenge/$opponent'),
    headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    encoding: utf8,
    body: {'rated': 'false', 'color': color.name, 'variant': variant.name},
  );
  if (response.statusCode != 200) throw response.body;
  stdout.write(
    'Sent challenge to $opponent for ${variant.displayName} (${color.name})...',
  );
}

Future<void> acceptChallenge(
  Challenge challenge,
  Set<String> allowedOpponents,
  String apiKey,
) async {
  if (!allowedOpponents.contains(challenge.challenger.username)) {
    print('Ignoring challenge from ${challenge.challenger.username}');
    return;
  }

  stdout.write(
    'Accepting challenge from ${challenge.challenger.username} for ${challenge.variant.displayName} (${challenge.color.name})...',
  );
  var response = await http.post(
    Uri.parse('https://lichess.org/api/challenge/${challenge.id}/accept'),
    headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    encoding: utf8,
  );
  if (response.statusCode != 200) throw response.body;
  print(' Done!');
}

bool Function(Game) matchesGameColor(Color color) {
  return (game) => colorsEqual(game.color, color);
}

bool colorsEqual(Color color1, Color color2) {
  return color1 == color2 || color1 == .random || color2 == .random;
}

Future<List<Game>> getGames(String apiKey) async {
  var map = await fetch(
    Uri.parse('https://lichess.org/api/account/playing?nb=50'),
    apiKey,
  );
  return NowPlaying(map).nowPlaying;
}

Future<Challenges> getChallenges(String apiKey) async {
  var map = await fetch(Uri.parse('https://lichess.org/api/challenge'), apiKey);
  return Challenges(map);
}

Future<Map<String, Object?>> fetch(Uri uri, String apiKey) async {
  var response = await http.get(
    uri,
    headers: {'Authorization': 'Bearer $apiKey'},
  );
  if (response.statusCode != 200) throw response.body;

  return jsonDecode(response.body) as Map<String, Object?>;
}
