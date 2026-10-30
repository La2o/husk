# ITRTG official Play Games online Save / Load — integration status

This is about **the game's own online Save / Load**, not Husk ZIP/iCloud backup and not generic Google Drive access.

## Current status: blocked on a genuine Play Games identity, not complete

ITRTG (`de.shugasu.itrtg`) version 4.66 uses Google Play Games for its **Android player identity** and saves progress to **Shugasu's own server**. According to the developer's privacy documentation, Android saves are keyed to the Google Play Games ID; the online data is not a Google Drive backup. The game's startup currently reports Play Games Plugin 2.1.0 and `Logged in = False` in Husk.

Husk's translation layer does not run Google's Play Services sign-in implementation. The following are **stubs**, not an authenticated session:

- `src/translation-layer-next/husk-tl-jni-gms.c`
  - `SignIn_result` returns a completed task with an `AuthenticationResult` object.
  - `Auth_isAuthenticated` always returns false.
  - `PlayersClient.getCurrentPlayerId` / `getCurrentPlayer` return `Task_failed` with `API_NOT_CONNECTED`.
- `src/java-framework/src/husk/GmsProviders.java`: Google accounts provider responds with an empty account list.
- `src/java-framework/src/android/accounts/AccountManager.java`: no Google accounts are available.
- `src/app/Husk/Play/GoogleSignInSheet.swift`: the Google sign-in flow is for obtaining **Play Store download credentials**, not a Play Games OAuth session. Do **not** reuse its tokens for game identity.
- `src/java-framework/src/husk/GooglePackages.java`: advertises Google packages for compatibility; this does not implement their authenticated services.

## External identity dependency

Google Play Games v2 platform authentication requires a Google Play Games developer project and correctly associated OAuth2 credentials. Google provides a **game-scoped** player identifier, not merely an email address or a standard Google account subject. This app's public ID and/or authorization setup is controlled by its publisher (Shugasu), through the Google Play Console.

A standalone OAuth client made by the Husk fork cannot be assumed to obtain **ITRTG's** game-scoped ID or to authenticate to the ITRTG game backend. Supplying a manually invented ID or reporting `isAuthenticated = true` without a real verified session is **not** an acceptable fix.

ITRTG dev contact: support@shugasu.com (listed on the official changelog); request an **officially supported authentication / account transfer path** suitable for Husk / iOS. Never request their private OAuth client secret.

## Required implementation milestones

1. Determine exactly which `PlayGames` / `GamesSignInClient` / `PlayersClient` methods ITRTG's Play Games Unity Plugin 2.1.0 invokes, including asynchronous `Task` completion and callbacks (use its APK with consent and Husk's JNI logs). Avoid recording auth tokens.
2. Establish a **legitimate** Play Games authentication provider:
   - a real Google Play Games/Google Play Services environment authorized for ITRTG, or
   - a publisher-approved OAuth2 integration whose client is associated with the game's Play Games configuration.
   If neither exists, mark the feature unavailable; **never** emulate successful sign-in.
3. Once authenticated, obtain the **ITRTG game-scoped** player ID through Google Play Games and verify the identity belongs to the signed-in player; securely store and refresh credentials, support sign-out/revoke.
4. Build the bridge from native auth results to Husk's Java/JNI `Task` objects for `isAuthenticated`, `signIn`, `getCurrentPlayerId`, and `getCurrentPlayer`; add error and expiration behavior. Calls must be genuinely asynchronous where the SDK expects asynchronous `Task` completion.
5. Test game startup → authenticated → `Load Online` → restart → `Save Online` with a consenting real Google account on a test save. **Load existing online progress before allowing a new local game to autosave**, since ITRTG may autosave to the publisher's server.
6. Test revoked/expired credentials, wrong game client, offline mode, a second device, and manual disconnect; protect data against wrong-user restore.

## Why we did not ship a fake-login IPA

The existing game starts successfully after the Unity6 mapping workaround. Switching Husk's stubs to `authenticated = true` or returning a static player ID would not prove identity to Google, cannot be trusted to restore the correct Shugasu save, and may overwrite data. No working official Play Games backend is implemented by this documentation branch.

## References

- ITRTG's online-save identity policy: https://www.shugasu.com/games/itrtg/privacy.html
- ITRTG developer notes on game-specific IDs (April 10, 2026): https://shugasu.com/games/itrtg/changelog.html
- PGS platform authentication: https://developer.android.com/games/pgs/platform-authentication
- PGS server-side access: https://developer.android.com/games/pgs/android/server-access
- PGS game-scoped IDs: https://developer.android.com/games/services/web/api/rest/v1/players/getScopedPlayerIds
- OAuth credential association with Play Console project: https://developer.android.com/games/pgs/console/setup
