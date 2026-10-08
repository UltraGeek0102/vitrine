# Vitrine

A Theos tweak (Objective-C + Logos) injected into the decrypted Spotify iOS app. The full guide is
`docs/tweaks.md`; read it before changing code.

## Two looks, never both

**Redesigned UI** (the first row of Mod Settings) picks one of two looks, read once at launch:

- **Native**: Spotify's own screens with the mod's tweaks on them (hide switches, glass header buttons,
  Home gradient, AMOLED switch, accent color...).
- **Redesigned**: the mod's own Liquid Glass look, from a clean sheet. It includes the glass tab bar,
  search field and now playing bar, the redesigned player and lyrics page with Apple Music style lyrics
  always on, a decluttered Home, Search's categories on tinted glass, a Library with one large title, the
  playlist, album and artist pages the way the Music app lays them out with one pinned ⋯ over each, black
  throughout, and its own accent color. No native tweak runs.

Anything that doesn't draw on Spotify's screens works the same under both: ads, privacy, lyrics
sources, gestures, blocked artists, flags, Vibrations, Speed and pitch, and the Live Activity. Those
last three were the redesign's until they moved to `Shared/`, so their keys lost the `.redesign.` and
`Core/SGPrefs.h`'s `SGMigrateKey` carries the old ones over at launch.

**The redesign is built for iOS 26.** It is Liquid Glass, which the system draws from 26 on and no older OS
can be given. `SGRedesignAvailable()` (`Core/SGUIMode.h`) says whether this OS has it. Below 26 the
redesign runs only after a warning that it is untested there (`SGKeyRedesignUntested`, stored by
`SGSetRedesignedUI` in `App/Pages.m`), and a launch with it that hangs (issue #37) is followed by one in
the native look with both switches off. The native look's floor is iOS 16.1, which is
Spotify 9.1.78's own. Vitrine is made for Spotify 9.1.78, and 9.1.88 likely works: it ran cleanly in a short test, so
the install warning leaves it alone (`SGSpotifyLikelyWorks` in `App/Onboarding/Onboarding.h`). The IPA build reads
Spotify's flag table from the IPA it builds, and again when the version changes.

## Where code goes (`tweak/Sources/`)

| Layer | What | Gate at the top of every `%ctor` |
|---|---|---|
| `Shared/` | behavior and data, either look | none |
| `Native/` | Spotify's screens tweaked | `if (!SGNativeUI()) return;` |
| `Redesigned/` | the redesign (`Kit/` + parts) | `if (!SGRedesignedUI()) return;` |
| `App/` | Mod Settings root and combined pages, Mod page, tour | none |
| `Core/`, `Settings/`, `Headers/`, `Diagnostics/` | infrastructure | none |

Rules:

- Imports run one way: `Core <- Settings <- Shared <- Native | Redesigned <- App`. Native and
  Redesigned never import each other. `scripts/check-layers.sh` runs before every build and fails on a
  violation. Don't work around it.
- Change one look without touching the other. When both need the same thing, each side keeps its own
  copy under its own names (`SG…` native, `SGR…` redesign) and its own keys. Examples are the tab bar
  composition and editor, AMOLED and the accent color. Don't merge copies back into
  a shared file.
- A lower layer that needs something from a higher one gets it through a registry in `Core`
  (forced flags: `Core/SGFlagForce.h`) or a function declared low and defined high.
- Settings: each layer builds its own rows and sections. `App/Pages.m` and `App/ModSettings.x`
  decide what to show from `SGRedesignedUIStored()`, so native-only pages disappear in the redesign.
- Keys start with `spotifyglass.` (redesign-only ones with `spotifyglass.redesign.`). Switches are
  read at launch, so a change needs a restart.

## Working on it

- Build: `make install` (signs and pushes to the phone), `make quick` (a tweak-only change, in seconds), `make release` (IPA only). Tweak only:
  `env -u MAKELEVEL gmake -C tweak clean package`.
- Look at Spotify's views through recorded trees (`make session` records clean ones into
  `trees/clean/`) before hooking anything. Prove every class and selector against the tree or the binary.
- Device log: `make log` (`[spotifyglass]` lines).
- Releases: Release Please (`.github/workflows/release.yml`). Commit as `feat:` / `fix:` (they bump
  `version.txt` and fill `CHANGELOG.md`; `chore:`, `refactor:` and `docs:` stay out). Merging its
  release PR tags `vX.Y.Z` and builds the tweak to check it compiles; nothing is attached. Never edit `version.txt` by hand.
- Known traps: anything pushed onto Spotify's nav stack must conform to `SPTPageController`
  (`Settings/SGPage.m`). Setting `hidden` on views inside Spotify's `OverflowStackView` or its Encore
  stacks crashes, so use alpha. A `CADisplayLink` capped at 60 Hz drags the player's 120 Hz
  transitions down with it. Never observe a notification that other threads post (`NSUserDefaultsDidChangeNotification`,
  `AVAudioSessionRouteChangeNotification`) with `queue:NSOperationQueue.mainQueue`: the posting thread waits
  for main, and at launch main waits on Spotify's CoreThread, so Spotify hangs and is killed. Use `queue:nil`
  and `dispatch_async` to main. Glass takes the appearance it inherits, and outside Spotify's navigation
  stacks (the tab bar, the now playing bar, the player) that is the system's: set every pane of the
  mod's to `overrideUserInterfaceStyle = UIUserInterfaceStyleDark`, or it goes light in light mode. Present a
  controller of the mod's through `SGPresentDark` (`Core/SGGlass.h`): a sheet's glass is its presentation's, and the
  controller's own override does not reach it.
