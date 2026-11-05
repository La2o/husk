# Idling to Rule the Gods, Play Games and cloud saves (this fork)

This fork is Husk 3.4 (Leviidev/Husk, build 149) with three changes on top, made so that Idling to Rule the Gods
(`de.shugasu.itrtg`, Unity 6) plays on an iPhone with its online saves:

1. **Google Play Games signs in with your own Google account.** The game's Save Online / Load Online use the same player as
   on Android, so they reach the same saves on Shugasu's server.
2. **Every game's saves go to iCloud Drive.** You choose a folder once. After that, each time you leave Husk with a game
   loaded, that game's saves are copied there, and the last ten are kept.
3. **Unity 6 fixes.** Unity's writable data no longer ends up in JIT memory, which made the game crash at start with SIGBUS.
   ITRTG also hands each frame to the screen on the GPU instead of copying it through the CPU.

## Install

Add this source in Feather, AltStore or SideStore. Its address does not change:

    https://github.com/La2o/husk/releases/download/feed/source.json

Every push to this branch builds a new IPA (`.github/workflows/husk-ipa.yml`). It is published as a release tagged
`fork-3.4-<run>`, and the source is updated to list it. Sign it with your own certificate. The bundle id is Husk's own
(`com.husk.app`), so it installs over Husk and keeps your games. Back up your saves first anyway.

## Setting up ITRTG's online saves

1. In Husk, sign in to the **Store** tab with **Sign In with Google**, using the account you play ITRTG with on Android.
   The guest (Aurora) account has no Play Games player, so it cannot be used.
   If you press Play on ITRTG with no Google account in Husk, Husk asks once whether to sign in first.
2. Open ITRTG's page in the Library. Under **Cloud Saves**, press **Check Play Games Sign-In**. It should show your Play
   Games player and its ID, which is the same ID the game uses on Android.
3. Play. The game signs in by itself at start, just as it does on Android.
   - **To continue an Android game:** before the game autosaves, use **Load Online** in ITRTG's own menu. It loads the
     progress stored under your player.
   - **To move this game somewhere else:** use **Save Online**. ITRTG also saves online by itself every 30 minutes.
4. Optional: under **Cloud Saves**, choose an **iCloud Drive folder**. A good choice is a new folder called "Husk Saves".
   Leave **Back Up When Leaving Husk** on. **Restore Latest from iCloud Drive** brings the newest copy back. It does that on
   this iPhone or another one, after you close and reopen Husk.

## How the sign-in works

On Android, Play services signs a game in. It asks `android.clients.google.com/auth` for a token in the game's name. The
request carries the game's package and the SHA-1 of the certificate its APK is signed with, which tells Google which
game's Play Console project the token is for. Play services then reads the player from
`www.googleapis.com/games/v1/players/me`.

Husk makes the same two requests (`src/app/Husk/Play/PlayGamesSignIn.swift`):

- it uses the long-lived account token from the Store sign-in, which Husk already keeps for Play Store downloads;
- it uses the game's own package, and the certificate digest read from the APK's v3/v2 signing block or its v1 PKCS#7 file;
- Play services is named as the caller, and the scope is `games_lite`.

The answer is a real player that Google returns for that account in that game. Husk never invents an ID and never claims
a sign-in Google did not make. With no Google account in Husk, the game is told the player is signed out, exactly as
before. `requestServerSideAccess` (a server auth code for a game's own backend) is answered the same way, with
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

## If something is wrong

- **"Check Play Games Sign-In" says the account's sign-in has expired:** sign out of the Store and sign in again.
- **It says the account has no Play Games profile:** open Google Play Games once on an Android device, or at
  play.google.com/games, then try again.
- **It says Google wants consent (`NeedPermission`):** sign in to ITRTG once on an Android device with that account.
- **The picture is wrong (black, frozen, torn):** in the game's **Game Settings**, set **Frame Handoff** to **CPU Copy**.
  The game then uses the original copy path.
- **The game crashes:** the next launch of Husk shows the report. Native crashes, SIGTRAP and SIGBUS included, are now
  named in it.

The game's log (its page › Technical Details › Share Log) says whether Play Games signed in, and if not, why
(`gms: Play Games signed in (player …)` or `gms: Play Games signed out: …`). Husk's own log has the same steps under `pgs`,
and the iCloud Drive copies under `saves`.
