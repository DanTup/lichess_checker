import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:lichess_checker/config.dart';
import 'package:lichess_checker/types.dart';

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

  final apiKey =
      config.apiKey ?? Platform.environment['LICHESS_KEY'];

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

  final desiredGames = config.games;
  final random = Random();

  final challenges = await getChallenges(apiKey);
  final playerChallenges = <String, List<Challenge>>{};
  final playersWithOutboundChallenges = <String>{};
  for (var challenge in [
    ...challenges.inChallenges,
    ...challenges.outChallenges,
  ]) {
    playersWithOutboundChallenges
      ..add(challenge.challenger.username)
      ..add(challenge.destUser.username);
    playerChallenges
        .putIfAbsent(challenge.challenger.username, () => [])
        .add(challenge);
    playerChallenges
        .putIfAbsent(challenge.destUser.username, () => [])
        .add(challenge);
  }

  final games = await getGames(apiKey);
  final playerGameType = <String, Map<Variant, List<Game>>>{};
  for (var game in games) {
    playerGameType
        .putIfAbsent(game.opponent.username, () => {})
        .putIfAbsent(game.variant, () => [])
        .add(game);
  }

  if (challenges.inChallenges.isNotEmpty) {
    print('Incoming challenges:');
    for (var challenge in challenges.inChallenges) {
      print(
        [
          '',
          challenge.challenger.username.padRight(15),
          challenge.destUser.username.padRight(15),
          ('${challenge.variant.displayName} (${challenge.color.name})')
              .padRight(25),
          challenge.url.padRight(50),
        ].join('  |  '),
      );
    }
    print('');
  }

  if (challenges.outChallenges.isNotEmpty) {
    print('Outbound challenges:');
    for (var challenge in challenges.outChallenges) {
      print(
        [
          '',
          challenge.challenger.username.padRight(15),
          challenge.destUser.username.padRight(15),
          ('${challenge.variant.displayName} (${challenge.color.name})')
              .padRight(25),
          challenge.url.padRight(50),
        ].join('  |  '),
      );
    }
    print('');
  }

  print('Open Games:');
  var missingVariants = <String, List<DesiredGame>>{};
  for (var MapEntry(key: opponent, value: variants) in desiredGames.entries) {
    for (var desiredGame in variants) {
      var variant = desiredGame.variant;
      var color = desiredGame.color;
      var theseGames = playerGameType[opponent]?[variant] ?? [];
      for (var game in theseGames.where(matchesGameColor(color))) {
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
      if (!theseGames.any(matchesGameColor(color))) {
        missingVariants.putIfAbsent(opponent, () => []).add(desiredGame);
        print(
          [
            '',
            opponent.padRight(15),
            ('${variant.displayName} (${color.name})').padRight(25),
            '** Missing! **'.padRight(15),
            ''.padRight(50),
          ].join('  |  '),
        );
      }
    }
  }
  print('');

  for (var MapEntry(key: opponent, value: missingGames)
      in missingVariants.entries) {
    var currentGamesCount =
        (playerGameType[opponent]?.values.expand((games) => games).length ?? 0) +
        (playerChallenges[opponent]?.length ?? 0);
    var allowedGamesCount =
        config.maxGamesForOpponent(opponent) ?? desiredGames[opponent]!.length;
    var availableGameSlots = allowedGamesCount - currentGamesCount;
    if (availableGameSlots <= 0) {
      continue;
    }

    var gamesWithoutChallenge = missingGames.where((desiredGame) {
      return !(playerChallenges[opponent]?.any(
            (challenge) =>
                challenge.variant == desiredGame.variant &&
                colorsEqual(desiredGame.color, challenge.color),
          ) ??
          false);
    }).toList();
    if (gamesWithoutChallenge.isEmpty) {
      continue;
    }

    var priorityGames =
        gamesWithoutChallenge.where((game) => game.priority).toList();
    var randomGames =
        gamesWithoutChallenge.where((game) => !game.priority).toList()
          ..shuffle(random);
    var gamesToChallenge = [
      ...priorityGames,
      ...randomGames,
    ].take(availableGameSlots).toList();
    if (gamesToChallenge.isEmpty) {
      continue;
    }

    // Can we send a challenge?
    if (!playersWithOutboundChallenges.contains(opponent)) {
      playersWithOutboundChallenges.add(opponent);
      var gameToChallenge = gamesToChallenge.first;
      await sendChallenge(
        opponent,
        gameToChallenge.variant,
        gameToChallenge.color,
        apiKey,
      );
    }
  }

  for (var challenge in challenges.inChallenges) {
    await acceptChallenge(challenge, desiredGames, apiKey);
  }
}

Future<void> sendChallenge(
  String opponent,
  Variant variant,
  Color color,
  String apiKey,
) async {
  stdout.write(
    'Sending challenge to $opponent for $variant (${color.name})...',
  );
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
  print(' Done!');
}

Future<void> acceptChallenge(
  Challenge challenge,
  Map<String, List<DesiredGame>> desiredGames,
  String apiKey,
) async {
  if (!desiredGames.containsKey(challenge.challenger.username)) {
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
