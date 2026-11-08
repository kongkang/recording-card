# Recording-card OAuth and model gateway

This is a minimal adaptation of the read-only `reai_mobile_app` OAuthClient,
OAuthTokenStore and AuthorizedHttpClient designs at reference revision `7f9d13a`.
It deliberately does not import AuthStore, Supabase, WeChat SDK, keyboard/native
code, demo credentials, provider keys or tokens. The text gateway follows the
reference `/api/model-gateway/v1/models` and `/chat/completions` contract.

```dart
final auth = AuthService();
await auth.restore(); // Secure storage, refresh as needed, then GET /profile.
await auth.signInWithOAuth(loginHint: 'optional-email-hint');
final gateway = ModelGateway(auth: auth);
final permitted = await gateway.listTextModels();
// Selection policy belongs to caller/config; there is no hidden model fallback.
final text = await gateway.complete(prompt, model: selectedAuthorizedModelId);
await auth.signOut(); // Immediate local logout + revoke; await and catch errors.
auth.dispose();
```

The original synchronous `signIn(account, password)` is retained only for source
compatibility and always returns an error. It cannot create a local session.
`AuthService.session` is read-only and contains no tokens. OAuth cancellation,
invalid callback, missing server configuration and unavailable secure storage
are failures, never simulated sign-in success.

Production storage uses iOS Keychain `unlocked_this_device` and Android encrypted
shared preferences. Token and expiry values are written as a single JSON bundle;
PKCE pending state/verifier is one separate expiring bundle. Keys are scoped to
`recording_card.oauth.v1.<sha256(issuer/client/redirect/scope)>`, and only these
keys are deleted. Changing configuration will not reuse prior client tokens.
Unlike the reference's full migration flow, there is no reinstall first-run
shared-preferences marker; iOS Keychain may survive uninstall. Explicit sign-out
and server revocation are required when retiring an installation.

Both OAuth token requests and authorized API requests enforce a nonempty exact
HTTPS host allowlist. Subdomains, credentials in URLs, alternate ports, queries,
fragments and HTTP redirects are rejected. No server error bodies, tokens or
callback URLs are included in exception messages. Refresh uses single-flight
rotation and serialized writes; identity epochs prevent old requests or refresh
results from crossing a logout/new-login boundary.

The temporarily reused reference public-client ID is configurable and is NOT a
client secret. Default callback is **`recording-card://callback`**, never the
reference `reai-mobile` scheme. Before real testing, the server registration must
allow this exact redirect and the requested `mobile:full profile:read` scopes.
The client cannot bypass the server allowlist.

Configuration can be injected with `ClientConfig` or through `RC_API_BASE`,
`RC_OAUTH_BASE_URL`, `RC_OAUTH_CLIENT_ID`, `RC_OAUTH_REDIRECT_URI`, `RC_OAUTH_SCOPE`,
`RC_MODEL_GATEWAY_BASE_URL`, and `RC_TEXT_MODEL`. `RC_API_BASE` retains its original
getter compatibility and, when explicitly defined, overrides OAuth/business
bases. An invalid explicit override fails rather than choosing a default host.
The only default approved host is `block2-api.wainao.chat`; a different deployment
requires an explicitly approved host list through injected `ClientConfig`.
`RC_TEXT_MODEL` defaults to empty, so callers must pass an authorized model or
provide a configured one. No API keys or client secrets are supported.

For tests, inject `OAuthClient`, `OAuthTokenStore(TokenStorage)`,
`WebAuthLauncher`, and `http.Client`. All test-only in-memory storage/browser
fixtures live in `test/a_auth/`; no fake implementation is used by default.

Dependencies: `http ^1.2.0`, `crypto ^3.0.3`, `flutter_secure_storage ^9.2.0`,
`flutter_web_auth_2 ^4.1.0`. Manifest/lock/platform integration belongs to the
integration owner, not this module commit. Android must register the plugin
CallbackActivity for `recording-card` with host `callback`, retain singleTop and
remove task-affinity entries, grant INTERNET, and exclude secure-storage data
from backup (or disable backup). iOS uses system ASWebAuthenticationSession;
registering the independent URL scheme in Runner Info.plist documents the app's
namespace, although custom-scheme ASWebAuthenticationSession itself needs no
extra universal-link entitlement. Use an SDK supporting the plugin's iOS 17.4
APIs (Xcode 15.3+), and verify actual supported runtime versions on the target
phone. The plugin source provides fallback paths and its podspec still says
minimum 11.0; its README upgrade notice alone should not be mistaken for a
verified app deployment target. This Linux test run does not validate Keychain,
Custom Tabs, ASWebAuthenticationSession, callback capture, signing or a phone.

Pending authorization survives in secure storage but a killed browser Future is
not resumed on cold start; the user restarts login. No app_links/second callback
receiver is introduced. Reference repository root has no explicit LICENSE file
in this checkout; internal reuse was user-authorized, but release licensing
should be confirmed rather than inferred from repository access.
