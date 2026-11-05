# Idling to Rule the Gods and its online saves (this fork)

This fork is Husk 3.4 (Leviidev/Husk, build 149) with two changes on top, made so that Idling to Rule the Gods
(`de.shugasu.itrtg`, Unity 6) plays on an iPhone with its online saves:

1. **Google Play Games signs in with your own Google account.** The game's Save Online / Load Online then use the same player
   as on Android, so they reach the same saves on Shugasu's server.
2. **Unity 6 fixes.** Unity's writable data no longer ends up in JIT memory, which made the game crash at start with SIGBUS.
   ITRTG also hands each frame to the screen on the GPU instead of copying it through the CPU.

## Install, and the test channel

Add this source in Feather, AltStore or SideStore. Its address does not change:

    https://github.com/La2o/husk/releases/download/feed/source.json

The source works as a test channel. Every push builds a new IPA (`.github/workflows/husk-ipa.yml`): a push to any branch
that has the workflow, or **Run workflow** on the Actions tab, which can also take a note of what to test. Each build is
published as a release tagged `fork-3.4-<run>` and added to the source:

- **Its version is 3.4.<run>** (build 149.<run>), so it is always newer than the Husk 3.4 it replaces, and newer than the
  build before it.
- **Its description in Feather** says which branch and commit it is from, what to test, and the commits since the build
  before. Builds of branches other than `main` are marked as test builds.
- **The release also carries `Husk.app.dSYM.zip`**, the debug symbols of that exact binary, for symbolicating an iOS crash
  report (`.ips`).
- **Husk's Settings and every log show the commit** a running build is from, so a log can be matched to its build.

Sign the IPA with your own certificate. The bundle id is Husk's own (`com.husk.app`), so it installs over Husk and keeps
your games. Back up your saves first anyway (the game's page › Back Up Saves).

## Setting up ITRTG's online saves

1. In Husk, sign in to the **Store** tab with **Sign In with Google**, using the account you play ITRTG with on Android.
   The guest (Aurora) account has no Play Games player, so it cannot be used.
   If you press Play on ITRTG with no Google account in Husk, Husk asks once whether to sign in first.
2. Open ITRTG's page in the Library. Under **Online Saves**, press **Check Play Games Sign-In**. It should show your Play
   Games player and its ID, which is the same ID the game uses on Android.
3. Play. The game signs in by itself at start, just as it does on Android.
   - **To continue an Android game:** before the game autosaves, use **Load Online** in ITRTG's own menu. It loads the
     progress stored under your player.
   - **To move this game somewhere else:** use **Save Online**. ITRTG also saves online by itself every 30 minutes.

## Debugging a build

When the online save does not find its player, or the game stops, these say why:

- **The game's log.** On the game's page, go to Technical Details › Share Log.
  - `gms: Play Games signed in (player …)` or `gms: Play Games signed out: <reason>` says whether the sign-in worked, and
    if not, why.
  - `gms: Play Games <call> -> <answer>` lines show each Play Games call the game made and what it got:
    `isAuthenticated`, `getCurrentPlayer`, the `Player` getters, `Tasks.whenAll` and `requestServerSideAccess`. For
    `requestServerSideAccess`, only the fact that a code was issued is logged, never the code.
  - `net: the game looks up <host>` lines show each server the game contacts, once each. If the save server never appears,
    the game never tried to reach it. `-- not found` means the name did not resolve.
- **Online Saves › Copy Sign-In Details.** This copies the build, the game, the SHA-1 of the APK's signing certificate, the
  Google account, the player and the last sign-in error. It includes no passwords and no tokens. The certificate SHA-1 should
  match the one Google Play lists for the game; an APK re-signed by someone else will not sign in.
- **Husk's own log** has the same steps under `pgs`.
- **A crash:** the next launch shows the report, which now names native SIGTRAP and SIGBUS crashes. The release's
  `Husk.app.dSYM.zip` symbolicates an iOS `.ips` crash report of that build.

## How the sign-in works

On Android, Play services signs a game in. It asks `android.clients.google.com/auth` for a token in the game's name. The
request carries the game's package and the SHA-1 of the certificate its APK is signed with, which tells Google which game's
Play Console project the token is for. Play services then reads the player from
`www.googleapis.com/games/v1/players/me`.

Husk makes the same two requests (`src/app/Husk/Play/PlayGamesSignIn.swift`):

- it uses the long-lived account token from the Store sign-in, which Husk already keeps for Play Store downloads;
- it uses the game's own package, and the certificate digest read from the APK's v3/v2 signing block or its v1 PKCS#7 file;
- Play services is named as the caller, and the scope is `games_lite`.

The answer is a real player that Google returns for that account in that game. Husk never invents an ID and never claims
a sign-in Google did not make. With no Google account in Husk, the game is told the player is signed out, exactly as
before. `requestServerSideAccess` (a code a game's own server trades with Google) is answered the same way, with
`oauth2:server:client_id:<the game's server client>:api_scope:…`.

The runtime asks through `husk_pgs_set_host` (`src/translation-layer-next/husk-tl-playgames.h`). The game's C# reaches Play
Games through JNI, and Husk's own answers in `husk-tl-jni-gms.c` come before the APK's Java, even on the Java runtime that
runs Unity 6. They answer these calls:

- `GamesSignInClient.isAuthenticated` / `signIn` / `requestServerSideAccess` (both forms);
- `PlayersClient.getCurrentPlayer` / `getCurrentPlayerId`, and the `Player` getters;
- `Tasks.whenAll`, which the Play Games Unity plugin (2.x) waits on after sign-in.

The objects made there (tasks, results, players) use classes of Husk's own (`husk/gms/…`). On the Java runtime, a field
that the APK's class does not declare is kept once per class rather than once per object. Each task's result would then
have overwritten the last one's, and the plugin would have read no player after `whenAll`.

When the game's screen opens, the sign-in starts (`PlayGamesSignIn.gameStarting`), so the answer is usually ready before
Unity asks for it. The player is remembered for the session. It is also remembered on disk, per account and game, so that
offline the game keeps the same identity, as Play services would.

## If the sign-in fails

- **The account's sign-in in Husk has expired:** sign out of the Store and sign in again.
- **The account has no Play Games profile:** open Google Play Games once on an Android device, or at
  play.google.com/games, then try again.
- **Google wants consent (`NeedPermission`):** sign in to ITRTG once on an Android device with that account.
- **The picture is wrong (black, frozen, torn):** in the game's **Game Settings**, set **Frame Handoff** to **CPU Copy**.
  The game then uses the original copy path.
