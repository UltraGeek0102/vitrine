# Lyrics translation check

`./build.sh` checks the parts of lyrics translation that need no network: Musixmatch's community
translations matched onto a song's lines by their folded text, as copies that leave the lines kept
before untouched (`SGMusixmatchTranslatedLines`); each AI provider's request (`SGAITranslationRequest`:
the URL, the key's header, the body, what the plain retry leaves out, a server URL that could carry a
secret refused) and its reply read into one translation per line or a reason to show
(`SGAITranslationsIn`): Gemini's blocked prompt, recitation or safety stop, OpenAI-compatible and
Anthropic refusals and length stops, a line count that does not match, the key, the limit; and saved
translation files with their source and from before sources were kept (`SGSavedTranslationLines`). It runs on the Mac as a Mac Catalyst binary, with no
simulator and no network.

It does not cover the requests themselves, the lines taking the translations as they are kept
(`Shared/Lyrics/KaraokeSource.x`), or the lyrics view picking them up.
