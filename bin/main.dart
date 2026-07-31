import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:lichess_checker/types.dart';

final apiKey = Platform.environment['LICHESS_KEY'];

const Map<String, List<(Variant, Color)>> desiredGames = {
  // Add an entry for each opponents username and the kinds of games to play.
  'dantup': [
    (Variant.standard, .black),
    (Variant.standard, .white),
    (Variant.antichess, .random),
    (Variant.atomic, .random),
    (Variant.crazyhouse, .random),
    (Variant.horde, .random),
    (Variant.racingKings, .random),
    (Variant.threeCheck, .random),
    (Variant.kingOfTheHill, .random),
    (Variant.chess960, .random),
  ],
};

Future<void> main(List<String> arguments) async {
  if (apiKey == null) {
    stderr
      ..writeln('The LICHESS_KEY environment variable is not set!')
      ..writeln('')
      ..writeln(
        'Create a PAT at https://lichess.org/account/oauth/token/create with the following permissions:',
      )
      ..writeln('')
      ..writeln('- Read incoming challenges')
      ..writeln('- Send, accept and reject challenges')
      ..writeln('')
      ..writeln('Then set it in the LICHESS_KEY env variable');
    return;
  }

  final challenges = await getChallenges();
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

  final games = await getGames();
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
  var missingVariants = <(String, Variant, Color)>[];
  for (var MapEntry(key: opponent, value: variants) in desiredGames.entries) {
    for (var (variant, color) in variants) {
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
        missingVariants.add((opponent, variant, color));
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

  for (var (opponent, variant, color) in missingVariants) {
    // Check there is not already a challenge for this.
    if (playerChallenges[opponent]?.any(
          (challenge) =>
              challenge.variant == variant &&
              colorsEqual(color, challenge.color),
        ) ??
        false) {
      continue;
    }
    // Otherwise, can we send a challenge?
    if (!playersWithOutboundChallenges.contains(opponent)) {
      playersWithOutboundChallenges.add(opponent);

      await sendChallenge(opponent, variant, color);
    }
  }

  for (var challenge in challenges.inChallenges) {
    await acceptChallenge(challenge);
  }
}

Future<void> sendChallenge(
  String opponent,
  Variant variant,
  Color color,
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

Future<void> acceptChallenge(Challenge challenge) async {
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

Future<List<Game>> getGames() async {
  var map = await fetch(
    Uri.parse('https://lichess.org/api/account/playing?nb=50'),
  );
  return NowPlaying(map).nowPlaying;
}

Future<Challenges> getChallenges() async {
  var map = await fetch(Uri.parse('https://lichess.org/api/challenge'));
  return Challenges(map);
}

Future<Map<String, Object?>> fetch(Uri uri) async {
  var response = await http.get(
    uri,
    headers: {'Authorization': 'Bearer $apiKey'},
  );
  if (response.statusCode != 200) throw response.body;

  return jsonDecode(response.body) as Map<String, Object?>;
}
