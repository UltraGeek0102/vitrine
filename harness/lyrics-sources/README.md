# Lyrics sources check

`./build.sh` checks, on the Mac as a Mac Catalyst binary, with no simulator and no network:

- the word splitting in `Shared/Lyrics/KaraokeTiming.m`: long Thai, Lao, Khmer and Burmese lines with no
  spaces come apart at the dictionary's words, the pieces make up the line exactly, and Latin, Chinese and
  Japanese lines split as before. The pieces are printed, so a script the system does not split shows;
- KuGou's KRC (`KuGou.m`, read by `SGLyricsPieceLines` in `NetEase.m`): packed here the way KuGou packs
  it, then unpacked and read, with the word times, the joining and the line ends checked;
- NetEase's yrc and Musixmatch's richsync (`Musixmatch.m`), whose pieces `SGKaraokePieceLine` in
  `KaraokeTiming.m` runs together into words, as the Lyricsfile's are: which pieces join, and where each
  word and line ends;
- the QQ Music and KuGou asks against made-up search replies: titles, singers and lengths that do not
  fit are passed over, the closest KuGou lengths are tried first and at most three, and QQ's LRC is read.
- LRCLIB's Lyricsfile (`Lyricsfile.m`): the spec's example and LRCLIB's own way of writing it read as word
  timed lines, segments run together into words, a file timed only by the line left to the LRC, a broken
  or unknown file refused whole, and the LRCLIB ask taking the words over the LRC and a record with words
  over a closer one without, passing over a search record that is not the track (another song, another
  artist), and counting a record's words only once its Lyricsfile reads. The ask reads a Lyricsfile off the
  main queue and answers on it, later than a record without one.

`./build.sh krc.json qq.json lrclib.json` also reads real replies saved from `lyrics.kugou.com/download`,
QQ's `GetPlayLyricInfo` and LRCLIB's `/api/get/<id>`, and prints how many lines each has; an LRCLIB record
must read as word timed exactly when it says `hasWordSync`. None are kept here, since they are real lyrics.

It does not cover the requests themselves, the order on the Lyrics page, or the lines on the lyrics view.
