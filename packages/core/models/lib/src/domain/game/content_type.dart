enum ContentType {
  accessory,
  baseGame,
  bundle,
  dlc,
  expandedEdition,
  expansion,
  mod,
  port,
  remake,
  remaster,
  standaloneExpansion,
  unknown;

  static ContentType fromJson(String value) => switch (value) {
    'Accessory' => accessory,
    'BaseGame' => baseGame,
    'Bundle' => bundle,
    'DLC' => dlc,
    'ExpandedEdition' => expandedEdition,
    'Expansion' => expansion,
    'Mod' => mod,
    'Port' => port,
    'Remake' => remake,
    'Remaster' => remaster,
    'StandaloneExpansion' => standaloneExpansion,
    _ => unknown,
  };

  String toJson() => switch (this) {
    accessory => 'Accessory',
    baseGame => 'BaseGame',
    bundle => 'Bundle',
    dlc => 'DLC',
    expandedEdition => 'ExpandedEdition',
    expansion => 'Expansion',
    mod => 'Mod',
    port => 'Port',
    remake => 'Remake',
    remaster => 'Remaster',
    standaloneExpansion => 'StandaloneExpansion',
    unknown => 'Unknown',
  };
}
