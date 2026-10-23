# Genius lyrics check

`./build.sh` checks, on the Mac as a Mac Catalyst binary, with no simulator and no network:

- the song Genius's search reply gives a track (`SGGeniusSongIn` in `Shared/LyricsSources/SongMatch.m`),
  on replies carrying the titles and artists genius.com really answered for these tracks: a song of the
  same name by someone else is passed over (Yesterday by a HearonTrackz featuring Queen Key is not
  Queen's), a cover gets the singer's own page and nothing when Genius has none, a remix gets the remix
  it names and a plain track the song over its remixes, an instrumental or karaoke track gets nothing,
  tracks named by their lead artist alone, as the player names them, and two leads, a comma inside a
  name and a name Genius writes twice over ("BTS (방탄소년단)", "Дора (Dora)") still match;
- the lines read out of a made-up embed script (`SGGeniusEmbedRows` in `Shared/LyricsSources/Genius.m`):
  the two layers of escaping undone, tags and [Chorus] headings gone, entities decoded, one empty row
  per gap, and nothing at all for a page that is not the embed or an embed with no words.

`./build.sh live` (it needs the network, so not inside a sandbox that blocks it) also searches
genius.com for the same tracks, reads each match's real embed, and runs the whole ask once. Only line
counts are printed, since the words are real lyrics.

It does not cover the walk down the sources, the order on the Lyrics page, or the lines on the lyrics view.
