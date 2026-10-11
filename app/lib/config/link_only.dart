/// Build a Windows edition that only serves files over Wi-Fi links.
/// Enable with --dart-define=LOCALSEND_LINK_ONLY=true.
const linkOnlyMode = bool.fromEnvironment('LOCALSEND_LINK_ONLY');
