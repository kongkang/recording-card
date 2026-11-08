library;

/// Production authentication is OAuth only. Other values disable sign-in;
/// they NEVER enable local/password authentication. Tests inject dependencies.
const String kAuthMode = String.fromEnvironment(
  'RC_AUTH_MODE',
  defaultValue: 'oauth',
);
const bool kIsOAuthAuthMode = kAuthMode == 'oauth';
