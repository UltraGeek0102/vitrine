# Radio shuffle and repeat

Run `harness/radio-modes/build.sh` on macOS. It compiles the production
`Shared/AdBlock/RadioModes.m` against Foundation mocks of the observed Spotify APIs.
Spoof Premium on and off each pass 435 checks.

Coverage includes allowlisted/mixed/unknown restrictions, exact command mode and
boolean values, preserving copied command options, unmodified normal requests,
combined repeat requests, rejecting incidental speed/mode changes, nested calls,
exceptions, thread-local isolation, raw restriction copies/serialization, transient
empty state, revocation by explicit restrictions, playback/context changes, and
missing state or identity. The mocks model the combined request's nested optional
boolean getters: Spotify does not call its `setOptions:` setter when constructing
that request. These tests verify hook behavior, not Spotify core behavior.

## Device evidence (2026-10-09)

Tested on the paired iPhone 15 Pro, Spotify 9.1.88, Spoof Premium enabled, native
player. An auxiliary dylib containing this production source was added to the
existing development app to preserve its separate lossless experiment. The
complete main-checkout tweak also builds successfully.

The failing session was radio/autoplay reached after single-track playback and
skipping. Raw restrictions were `{radio, endless_context, autoplay}` for shuffle
and repeat-context, and `{autoplay}` for repeat-track. A normal playlist accepted
shuffle/repeat before these hooks, so this evidence does not establish a general
9.1.78-to-9.1.88 regression.

A temporary device probe read the player's actual `SPTPlayerOptions`. With the final
command handling, consecutive single taps produced:

| Action | Shuffle | Repeat context | Repeat track |
|---|---|---|---|
| Initial | on | on | off |
| Shuffle 1 | off | on | off |
| Shuffle 2 | on | on | off |
| Shuffle 3 | off | on | off |
| Shuffle 4 | on | on | off |
| Repeat 1 | on | on | on |
| Repeat 2 | on | off | off |
| Repeat 3 | on | on | off |

This establishes accepted mode changes, rather than merely undimmed buttons. The
user also reported repeat-one working. End-of-track testing overlapped user input
and is not an isolated automated playback proof. Repeat-all in an endless context
has no finite end to loop back to; these hooks do not create a finite queue or prove
that radio recommendations are reordered. Physical-device behavior on 9.1.78,
Connect receivers, and the redesigned player was not retested here.

## Important implementation details

- Enable only with Spoof Premium; require the complete expected runtime API before
  installing any hooks. Unrecognized restriction reasons remain restricted.
- Filter the three reason getters for presentation. Preserve their original values
  during copying and serialization and read original implementations for commands.
- The core needs `ESPCommandOptions.overrideRestrictions` for these radio commands.
  Direct mode setters fill boolean request fields; repeat's combined options path
  obtains nested optional-boolean messages and fills their values instead.
- Spotify publishes temporary empty restriction sets between core updates. Remember
  positive radio reasons per player and exact playback ID/context URI so subsequent
  taps still carry the override. Missing identity, changed identity, malformed
  reasons, or explicit non-radio restrictions discard that eligibility. Empty
  reasons on a playback never observed as radio do not grant an override.
- Scope command decisions to the synchronous request construction on that thread;
  never leave a global override active for unrelated commands or async responses.

Temporary tracing is not part of the tweak or harness.
