# Dictation: behaviour

Dictation lets you talk to Claude Code instead of typing. You hold the dictation key (Space by
default) in a chat window, Bifrost listens through the microphone and turns your speech into text
on the Mac, and it types that text into Claude Code's prompt through the chat's pseudo-terminal
(PTY), just as if you'd typed it yourself. No audio and no text ever leaves the Mac. The speech
engine is Apple's `SpeechAnalyzer` with `SpeechTranscriber`, which needs macOS 26.

The Electron app is a reference for behaviour only (user rule, 2026-11-16), and the places where
the native app differs from it on purpose are listed in
`docs/ports/dictation/DELIBERATE-DIFFERENCES.md`. The
[keyboard input explainer](../explainers/keyboard-input.html#voice) has a diagram of the path from
your voice to the prompt.

The code is the `BifrostDictation` module. Its `Model` folder holds the plain rules: what a key
does in a chat (`DictationKeys.swift`), how text is typed, and the record of what the chat has
sent to the PTY. `Services` holds the dictation service, the dictation of one chat
(`ChatDictation`) with its chat input and hold key, the typer and the speech engines. `UI` holds
the green glow (`DictationGlow`), the level meter in the title bar (`DictationMeter`) and the
notice line (`DictationNoticeView`).

## The hold key

The dictation key does two jobs: a quick press types its character as usual, and a longer hold
starts dictation. Bifrost tells the two apart by time.

- When the key goes down, Bifrost waits 250 ms. If you let go before then, the key types its
  character like any other key.
- If the key is still down at 250 ms, dictation starts and the key types nothing. Letting go
  stops the dictation.
- If another key goes down during the wait, the dictation key types its character first, then the
  other key goes through, and dictation doesn't start. This keeps every space in the right place
  when you type fast. Key repeats of the dictation key do nothing.
- The key behaves as a normal key when you press it with Cmd, Control, Option or Shift, while an
  input method is composing text, and while the chat can't take dictation because it has no
  attach, it shows the agent view, or Claude Code is showing a choice.
- Losing the focus or closing the chat during a hold stops the dictation early.
- If you let go, or press another key, before the first sound level or text arrives, the key
  types its character first. Nothing green has shown yet, so you probably meant a slow space.
  Once the first level or text has arrived, or while the speech model downloads, the key types
  nothing.
- Any other key stops the dictation and its typer before the key reaches the PTY. After a release,
  while the final text is still being typed, a key waits and goes after the text. When the
  dictation key types its own character, it follows the same rule.
- When dictation can't start, because Claude Code is in vim mode, the chat has no PTY, there's no
  speech engine, or an error arrives before the first level or text, the held key types its
  character once, as a normal key.

## The dictation service

All chat windows share one dictation service, which owns the speech engine and passes each
dictation's events to the chat that started it.

- Only one dictation runs at a time, so starting one in another chat stops the first. Events go
  only to the chat that started the dictation, through the listen stream of its chat panel, and a
  new listen for the same chat ends the old one. Only a chat panel can start a dictation.
- There's one microphone, so a session begins only after the session before it has ended. If a
  begin hangs, it fails at the engine limit and the engine is released. The next start then boots
  a new engine without waiting for the stuck begin, which can no longer open the microphone.
- The engine boots on the first warm-up or start: it downloads the speech model if it has to, then
  loads it. A chat warms the engine when it gets the focus (if it has a dictation key) and each
  time the dictation key goes down. The engine is released after 5 minutes without use, but never
  during a model download or a dictation.
- Booting fails if the engine isn't ready within 10 s, and a begin fails if it hasn't opened a
  session within 10 s. Both calls wait on macOS's speech service, which can stop answering. A
  model download isn't held to that limit, because it can be slow and its progress only moves
  when data arrives, so the 10 s start again once the download ends. If the progress doesn't move
  for 2 minutes, though, the download has stalled: the engine fails with the no-model error, and
  the next hold starts the download again.
- After a failure at the 10 s limit, the next warm-up or start boots a new engine. After a boot
  that ends in an error instead of ready, a stalled download included, only a start boots it
  again, so focusing a chat never restarts a download.
- A dictation's events reach the chat one main-thread turn after the service sends them. This
  leaves one known and accepted edge case: a late end from an old dictation can stop a new one,
  when a begin takes longer than 1.5 s and the chat starts the next dictation in the same turn.
  It's very rare.
- Starting during a model download opens no microphone. The chat shows the download progress,
  then gets model-ready, and the notice asks you to hold the key again.
- Stopping gives the session's final text. The session waits at most 1.5 s for it, then gives
  whatever text it has so far. A stop that comes before the session begins gives an empty end, and
  the microphone never opens. A dictation stops by itself after 2 minutes.
- On the first start, when macOS hasn't been asked about the microphone yet, Bifrost asks and
  gives the `mic-asked` error straight away. If you refuse, the error is `mic-denied`, and its
  notice has a button that opens the Microphone pane of System Settings. The other error codes are
  `no-model`, `failed` and `no-helper`, which means this build has no speech engine.
- When macOS has no speech model for the system language, dictation uses English, and the notice
  says so once for each chat window.

### Vim mode

Dictation stays off while Claude Code's settings turn vim mode on, because in vim mode a dictated
letter could run as a command, and Bifrost can't see which mode the prompt is in. On each hold,
Bifrost reads the top level of `~/.claude.json` and `~/.claude/settings.json`. Vim mode is on when
`vimMode`, `vimModeEnabled` or `isVimModeEnabled` is true or "vim", or when `editorMode` or
`EDITOR_MODES` is "vim". A mode text counts as "vim" after the white space is trimmed
(`Character.isWhitespace`), in any case. Bifrost reads a file again only when its size or
modification time changes, skips a file over 20 MB, and keeps the last good value when a file
doesn't parse, since Claude Code may be halfway through writing it.

## The typer

The typer is the part of dictation that writes your words into the prompt. Speech recognition
keeps revising its guess while you talk, so the typer keeps correcting what it has typed.

- Each write takes the prompt from what the typer has typed so far to the newest text: first DEL
  characters, one for each Character to remove, then the new text. It only ever removes text it
  typed itself, so your own text stays.
- One write holds at most 100 UTF-16 units of text, cut at a Character boundary, and at most
  1,000 DELs. Writes are at least 20 ms apart, and after DELs the wait grows by 1 ms for every
  2 DELs.
- A line break or a tab becomes a space. Other control characters and format characters are
  dropped, but joiners and tags stay, because emoji and some scripts need them. Marks, joiners and
  skin tones at the very start of a dictation are dropped too, so they never join onto your text.
- A space goes first when the prompt already has text and its last Character isn't white space
  (`Character.isWhitespace`). On an empty prompt, a space goes first only when the dictation's
  first scalar is `/`, `!`, `?` or `#`, so it doesn't open one of Claude Code's menus or modes.
- Bifrost knows what's in the prompt from the typed tail: the last 1,000 Characters that the chat
  has sent to the PTY during this attach. A new attach clears it.
- The typer never sends Enter, a tab or Esc, and never reads the screen.
- The final text of a dictation is typed only after you release the key. Escape, Control+C, a
  blocking choice from Claude Code and the end of the PTY stop the typer at once, and what it has
  typed stays.
- A final text waits for any keys you pressed before its dictation began, and a key waits only
  for the final texts of dictations that began before it. If the end doesn't arrive within 2 s of
  the release, the waiting keys go anyway. Keys go as soon as the typer in front of them finishes,
  so nothing checks the typer on a timer.
- If no end arrives within 3 s of a stop, for example because the chat's PTY closed, the chat
  stops waiting for it, and the text typed so far stays.
- A chat runs one dictation at a time. A new hold before the last dictation has ended waits for
  that end, and for the first write of its final text.

## The look

The green look shows only while the microphone is open, and not during a model download. The
voice level, from 0 to 1 about 30 times a second, drives the level bar next to the mic icon in
the title bar (44 points wide), the green top border, its shadow and the glow below it. The level
rises with a time constant of 60 ms and falls with one of 150 ms, so the glow drops back quickly
between words.

The glow responds a little more to your voice than in the approved mock (user decision,
2026-11-18). At full voice it reaches 80 points down rather than 65, its strongest alpha is 0.77
rather than 0.65, and its ellipse widens from 55 % of the glow's width in a quiet room to 72 % at
full voice, where the mock kept it at 67 %. The ellipse stops at 72 % so the light still fades
out before the sides of the frame. A quiet room looks the same as before: at level 0 the glow is
so faint that the narrower ellipse changes no pixel by more than 1 of 255.

On the meter, a quiet room (-55 dB) is level 0 and a loud voice (-10 dB) is level 1, and the look
follows e = level^0.8. Normal speech, around -30 to -20 dB, lands at levels 0.56 to 0.78 (e from
0.62 to 0.82), in the upper middle of the range, so the curve stays as it is.

Notices appear in a small box at the top of the chat panel, clear of Claude Code's prompt at the
bottom. Their texts are friendly and match the Electron app:

| Notice | Text | Shows for |
| --- | --- | --- |
| Vim mode | "Dictation doesn't work with Claude's vim mode yet." | 6 s |
| No attach | "This chat window isn't connected to its session, so dictation can't start." | 6 s |
| Model ready | "The speech model is ready. Hold the key to dictate." | 6 s |
| English fallback | "Your language has no on-device speech model, so Bifrost uses English." | 12 s, once per chat window |
| `mic-asked` | "macOS is asking if Bifrost can use the microphone. Answer it, then hold the key again." | 12 s |
| `mic-denied` | "Bifrost can't use the microphone. Allow it in System Settings.", with an "Open System Settings" button | Until a dictation starts listening |
| `no-model` | "Bifrost can't get an on-device speech model right now. Hold the key to try again later." | 12 s |
| `failed` | "Dictation stopped. Hold the key to try again." | 12 s |
| `no-helper` | "Dictation isn't available in this build of Bifrost." | 12 s |
| Download | "Getting the speech model ready… 42%" | While a hold waits for the download |

The download percent is a whole number from 0 to 100, and it shows 100 only when the download is
complete. A new notice replaces the old one, and when a dictation starts listening, or a hold
first sees the download progress, any earlier notice goes.

The speech helper process of the Electron app, its pipe protocol and its fallback to the older
speech recogniser aren't carried over: the engine runs inside the app.
