<h1 align="center">Vitrine</h1>

<p align="center">Spotify, in glass.</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-000000?style=for-the-badge&logo=ios&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/Spotify-9.1.78-1ED760?style=for-the-badge&logo=spotify&logoColor=white" alt="Spotify 9.1.78">
  <img src="https://img.shields.io/badge/9.1.88-likely%20works-555555?style=for-the-badge&logo=spotify&logoColor=white" alt="Spotify 9.1.88 likely works">
  <img src="https://img.shields.io/badge/Objective--C-3A95E3?style=for-the-badge&logo=apple&logoColor=white" alt="Objective-C">
  <img src="https://img.shields.io/badge/GitHub_Actions-2671E5?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions">
  <img src="https://img.shields.io/badge/License-GPL_v3-blue?style=for-the-badge" alt="GPL-3.0">
</p>

<p align="center">
  <a href="#build-it">Build it</a> ·
  <a href="docs/tweaks.md">Hack on it</a>
</p>

<p align="center">
  <img src="docs/screenshots/now-playing.webp" width="16%" alt="Full screen player with lyrics">
  <img src="docs/screenshots/album.webp" width="16%" alt="Album">
  <img src="docs/screenshots/playlist.webp" width="16%" alt="Playlist">
  <img src="docs/screenshots/queue.webp" width="16%" alt="Queue">
  <img src="docs/screenshots/live-activity.webp" width="16%" alt="Live Activity on the lock screen">
  <img src="docs/screenshots/home.webp" width="16%" alt="Home">
</p>

A no-jailbreak Theos tweak that rebuilds Spotify for iOS in Liquid Glass, injected into your own
decrypted IPA and signed with your own certificate.

Vitrine is a fork of [spoti.pw](https://github.com/skopevoj/spoti.pw) by Vojtěch Škopek, taken from
0.21.1 (commit `c790445`, 2026-09-23), the last version released under GPL-3.0, and modified since.

Built and tested on **Spotify 9.1.78**. **Spotify 9.1.88** likely works too: it ran cleanly in a short test, with
Karaoke, the lock screen lyrics, the Live Activity and the native look not yet checked on it, so report what breaks.
The mod hooks Spotify's own classes, which change between releases, so any other version may build and then break.

| | |
|---|---|
| The redesign | **iOS 26+** |
| Legacy look | iOS 16.1+ |
| Live Activity | iOS 17+ |

The redesign is `UIGlassEffect`, which only exists from iOS 26. Below that the Redesigned UI switch
turns it on only after a warning that it is untested there, and a launch with it that hangs goes back
to Spotify's own screens with everything else the mod adds on top. Both live in Settings → Mod Settings.

## Build it

No IPA is distributed. Bring a decrypted **Spotify 9.1.78** IPA (or 9.1.88, see above); you get an unsigned
`vitrine-<mod version>.ipa` to sign with SideStore, Feather or any certificate signer. Releases have no `.deb`:
injected by hand, the tweak alone misses the app changes the redesign needs (its glass tab bar), the Live
Activity, Music Haptics in the background and Connect's local discovery, so build the IPA instead.

### Build with GitHub Actions

Fork the repo, enable Actions, run **Build IPA from your own Spotify IPA**. It takes a direct link to
your decrypted `.ipa` and hands the built IPA back as a workflow artifact. No Mac needed; the link is
masked in the log and the result stays in your fork.

### Build on a Mac

Theos in `~/theos` and Xcode with an iPhoneOS 26+ SDK (`xcode-select` it). An SDK in `~/theos/sdks`
alone builds too, but without the Live Activity. Then:

    brew install make ldid dpkg zsign libimobiledevice
    uv tool install "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw"

Put the decrypted `.ipa` in `ipa/`, then:

    make release    # out/vitrine-<version>.ipa, ready to sign
    make install    # the same, signed with your certificate and installed over USB or Wi-Fi

`scripts/pipeline.sh <ipa> --no-flex --keep-watch` keeps Spotify's Apple Watch app (**untested**). Only its
arm64 build survives decryption on an iPhone, so it can run only on an Apple Watch Series 9, Ultra 2 or newer, and
it needs a signer that renames the Watch app to your App ID and signs it with a profile of its own that includes the
Watch. `make install` does not do that yet.

`make install` reads `SIGN_P12`, `SIGN_PROFILE` and `SIGN_P12_PASSWORD` from `.signing.env`; copy
`.signing.env.example` and fill it in.

The first build spends a minute reading Spotify's flags out of your IPA. `make flags` regenerates it.

### Signing

Sign with a bundle id matching your certificate's App ID. If it doesn't match, the app still works
but tapping the player on the lock screen won't open it — and it tells you on first launch which id
to use. In Feather, copy the App ID into **Identifier** and leave **PPQ protection** off; AltStore,
SideStore and Sideloadly get this right on their own.

The app keeps Spotify's bundle id, so it installs over the real Spotify.

## Credits

[cyan](https://github.com/asdfzxcvbn/pyzule-rw) injects, [Theos](https://theos.dev) builds, and
[FLEX](https://github.com/FLEXTool/FLEX), as hopeless's AutoFLEX build in `vendor/`, is the inspector
the view trees are read through. The ad blocking and the Premium state are ported from
[EeveeSpotify Reincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated).

GPL-3.0. Not affiliated with Spotify.
