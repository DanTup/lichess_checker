import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:lichess_checker/config.dart';
import 'package:lichess_checker/types.dart';

final _webCommandParser = ArgParser()
  ..addOption(
    'host',
    defaultsTo: '127.0.0.1',
    help: 'The host/address to listen on.',
  )
  ..addOption(
    'port',
    defaultsTo: '0',
    help: 'The port to listen on (0 for a random available port).',
  );

final _argParser = ArgParser()..addCommand('web', _webCommandParser);

Future<void> main(List<String> arguments) async {
  ArgResults args;
  try {
    args = _argParser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    return;
  }

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

  if (args.command?.name == 'web') {
    final webArgs = args.command!;
    final host = webArgs['host'] as String;
    final port = int.parse(webArgs['port'] as String);
    await runWebServer(config, apiKey, host, port);
  } else {
    await runConsole(config, apiKey);
  }
}

// --- Console mode ---

Future<void> runConsole(AppConfig config, String apiKey) async {
  final desiredGames = config.games;

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
      await sendChallenge(opponent, variant, color, apiKey);
    }
  }

  for (var challenge in challenges.inChallenges) {
    await acceptChallenge(challenge, desiredGames, apiKey);
  }
}

// --- Web server mode ---

class _WebState {
  final Challenges challenges;
  final List<Game> games;
  final Map<String, List<(Variant, Color)>> desiredGames;
  final DateTime fetchTime;

  _WebState({
    required this.challenges,
    required this.games,
    required this.desiredGames,
    required this.fetchTime,
  });
}

Future<void> runWebServer(
  AppConfig config,
  String apiKey,
  String host,
  int port,
) async {
  _WebState? state;
  var isUpdating = false;

  Future<void> update() async {
    if (isUpdating) return;
    isUpdating = true;
    try {
      final desiredGames = config.games;

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

      var missingCount = 0;
      var myTurnCount = 0;
      var gameCount = 0;

      for (var MapEntry(key: opponent, value: variants)
          in desiredGames.entries) {
        for (var (variant, color) in variants) {
          var theseGames = playerGameType[opponent]?[variant] ?? [];
          final matching = theseGames.where(matchesGameColor(color)).toList();
          if (matching.isEmpty) {
            missingCount++;
            // Check there is not already a challenge for this.
            if (!(playerChallenges[opponent]?.any(
                  (challenge) =>
                      challenge.variant == variant &&
                      colorsEqual(color, challenge.color),
                ) ??
                false)) {
              if (!playersWithOutboundChallenges.contains(opponent)) {
                playersWithOutboundChallenges.add(opponent);
                await sendChallenge(opponent, variant, color, apiKey);
              }
            }
          } else {
            gameCount += matching.length;
            myTurnCount += matching.where((g) => g.isMyTurn).length;
          }
        }
      }

      for (var challenge in challenges.inChallenges) {
        await acceptChallenge(challenge, desiredGames, apiKey);
      }

      state = _WebState(
        challenges: challenges,
        games: games,
        desiredGames: desiredGames,
        fetchTime: DateTime.now(),
      );

      final timestamp = state!.fetchTime.toLocal().toString().substring(0, 19);
      print(
        '[$timestamp] $gameCount games, $myTurnCount my turn, '
        '$missingCount missing, '
        '${challenges.inChallenges.length} in, '
        '${challenges.outChallenges.length} out',
      );
    } finally {
      isUpdating = false;
    }
  }

  // Initial fetch before starting the server.
  await update();

  final server = await HttpServer.bind(host, port);
  print('Listening on http://${server.address.host}:${server.port}/');

  // Schedule background updates every 30 minutes.
  Timer.periodic(const Duration(minutes: 30), (_) => update());

  await for (var request in server) {
    // Trigger an async update on every page fetch.
    unawaited(update());

    final currentState = state!;
    request.response
      ..headers.contentType = ContentType.html
      ..write(buildHtml(currentState))
      ..close();
  }
}

String buildHtml(_WebState state) {
  final desiredGames = state.desiredGames;
  final playerGameType = <String, Map<Variant, List<Game>>>{};
  for (var game in state.games) {
    playerGameType
        .putIfAbsent(game.opponent.username, () => {})
        .putIfAbsent(game.variant, () => [])
        .add(game);
  }

  final buf = StringBuffer();
  final timestamp = state.fetchTime.toLocal().toString().substring(0, 19);

  buf.write('''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Lichess Checker</title>
<style>
  body { font-family: sans-serif; margin: 1em 2em; }
  table { border-collapse: collapse; margin-bottom: 1.5em; }
  th, td { border: 1px solid #ccc; padding: 0.3em 0.7em; text-align: left; }
  th { background: #eee; }
  .my-turn { font-weight: bold; color: #c00; }
  .missing { color: #c00; }
  a { color: #00f; }
</style>
</head>
<body>
<h1>Lichess Checker</h1>
<p>Last updated: $timestamp</p>
''');

  // Incoming challenges table.
  if (state.challenges.inChallenges.isNotEmpty) {
    buf.write('<h2>Incoming Challenges</h2>\n');
    buf.write(
      '<table><tr><th>From</th><th>To</th><th>Variant</th><th>Color</th><th>Link</th></tr>\n',
    );
    for (var challenge in state.challenges.inChallenges) {
      buf.write(
        '<tr>'
        '<td>${_esc(challenge.challenger.username)}</td>'
        '<td>${_esc(challenge.destUser.username)}</td>'
        '<td>${_esc(challenge.variant.displayName)}</td>'
        '<td>${_esc(challenge.color.name)}</td>'
        '<td><a href="${_esc(challenge.url)}">${_esc(challenge.url)}</a></td>'
        '</tr>\n',
      );
    }
    buf.write('</table>\n');
  }

  // Outbound challenges table.
  if (state.challenges.outChallenges.isNotEmpty) {
    buf.write('<h2>Outbound Challenges</h2>\n');
    buf.write(
      '<table><tr><th>From</th><th>To</th><th>Variant</th><th>Color</th><th>Link</th></tr>\n',
    );
    for (var challenge in state.challenges.outChallenges) {
      buf.write(
        '<tr>'
        '<td>${_esc(challenge.challenger.username)}</td>'
        '<td>${_esc(challenge.destUser.username)}</td>'
        '<td>${_esc(challenge.variant.displayName)}</td>'
        '<td>${_esc(challenge.color.name)}</td>'
        '<td><a href="${_esc(challenge.url)}">${_esc(challenge.url)}</a></td>'
        '</tr>\n',
      );
    }
    buf.write('</table>\n');
  }

  // Games table.
  buf.write('<h2>Games</h2>\n');
  buf.write(
    '<table><tr><th>Opponent</th><th>Variant</th><th>Color</th><th>Status</th><th>Link</th></tr>\n',
  );
  for (var MapEntry(key: opponent, value: variants) in desiredGames.entries) {
    for (var (variant, color) in variants) {
      final theseGames = playerGameType[opponent]?[variant] ?? [];
      final matching = theseGames.where(matchesGameColor(color)).toList();
      if (matching.isEmpty) {
        buf.write(
          '<tr>'
          '<td>${_esc(opponent)}</td>'
          '<td>${_esc(variant.displayName)}</td>'
          '<td>${_esc(color.name)}</td>'
          '<td class="missing">Missing</td>'
          '<td></td>'
          '</tr>\n',
        );
      } else {
        for (var game in matching) {
          final url = 'https://lichess.org/${game.gameId}';
          final status =
              game.isMyTurn ? '<span class="my-turn">My Turn</span>' : 'Playing';
          buf.write(
            '<tr>'
            '<td>${_esc(opponent)}</td>'
            '<td>${_esc(variant.displayName)}</td>'
            '<td>${_esc(game.color.name)}</td>'
            '<td>$status</td>'
            '<td><a href="${_esc(url)}">${_esc(url)}</a></td>'
            '</tr>\n',
          );
        }
      }
    }
  }
  buf.write('</table>\n');

  buf.write('</body>\n</html>\n');
  return buf.toString();
}

/// Escapes HTML special characters.
String _esc(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

// --- Shared helpers ---

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
  Map<String, List<(Variant, Color)>> desiredGames,
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

void unawaited(Future<void> future) {
  future.catchError((Object e) => print('Background update error: $e'));
}
