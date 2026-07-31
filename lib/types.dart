extension type NowPlaying(Map<String, Object?> _map) {
  List<Game> get nowPlaying =>
      (_map['nowPlaying'] as List).cast<Game>().toList();
}

extension type Challenges(Map<String, Object?> _map) {
  List<Challenge> get inChallenges =>
      (_map['in'] as List).cast<Challenge>().toList();

  List<Challenge> get outChallenges =>
      (_map['out'] as List).cast<Challenge>().toList();
}

extension type Game(Map<String, Object?> _map) {
  String get gameId => _map['gameId'] as String;
  bool get isMyTurn => _map['isMyTurn'] as bool;
  Color get color => Color.parse(_map['color'] as String);
  Opponent get opponent => Opponent(_map['opponent'] as Map<String, Object?>);
  Variant get variant =>
      Variant.parse((_map['variant'] as Map<String, Object?>)['key'] as String);
}

extension type Challenge(Map<String, Object?> _map) {
  String get id => _map['id'] as String;
  Color get color => Color.parse(_map['color'] as String);
  Opponent get challenger =>
      Opponent(_map['challenger'] as Map<String, Object?>);
  Opponent get destUser => Opponent(_map['destUser'] as Map<String, Object?>);
  Variant get variant =>
      Variant.parse((_map['variant'] as Map<String, Object?>)['key'] as String);
  String get url => _map['url'] as String;
}

extension type Opponent(Map<String, Object?> _map) {
  String get username => _map['username'] as String? ?? _map['id'] as String;
}

enum Color {
  black,
  white,
  random;

  static Color parse(String input) {
    return Color.values.asNameMap()[input]!;
  }
}

enum Variant {
  standard('Standard'),
  antichess('Antichess'),
  atomic('Atomic'),
  chess960('Chess 960'),
  crazyhouse('Crazyhouse'),
  horde('Horde'),
  kingOfTheHill('King of the Hill'),
  racingKings('Racing Kings'),
  threeCheck('Three-Check');

  final String displayName;
  const Variant(this.displayName);

  static Variant parse(String input) {
    return Variant.values.asNameMap()[input]!;
  }
}
