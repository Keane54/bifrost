# Writing docs for Bifrost

Docs are written for a person first: you, a new contributor, or someone who's simply curious about
how Bifrost works. They should read as if a thoughtful engineer wrote them, in natural, flowing
English that explains things clearly rather than listing them as tersely as possible.

## How to write

- **Write in connected sentences.** Join related ideas with "which", "and" or a comma instead of
  chopping them into short, abrupt statements. A paragraph should read smoothly from start to end.
- **Explain, don't just assert.** When you introduce an idea, say what it is and why it matters, and
  answer the question a reader will obviously ask next. "Each case of `AttachState` holds only its
  own data" means nothing on its own; explain what an attach state is and what that data is.
- **Spell things out the first time.** Write "a pseudo-terminal (PTY)" before you rely on "PTY", and
  describe a concept in words before you name the Swift type behind it. A glossary link adds
  detail, but it never replaces the meaning in the sentence.
- **Leave implementation detail to the code.** Facts like "the rules don't import AppKit, so tests
  check them as plain values" belong in code comments, not in a doc about how something works.
- **Be complete, then trim.** Cover what the reader needs to understand the idea, then cut repeats
  and filler. Don't cut so far that the text turns terse; a slightly longer sentence that reads
  naturally beats a short one that doesn't.
- **Lead with the big picture.** Open with what the thing is and why it exists, then go into how it
  works. Use lists or tables for rules and exact values (times, limits, paths), and prose for
  explanations.
- **Point to the code.** Name the file or type so a developer can find it. Don't paste code that the
  reader can open.
- **No history.** Say how things are, not how they got that way.
- **Humanise it.** Run the final text through the `bifrost-humanise` skill. Contractions and "you"
  are fine. British spelling.

Nothing in this repo uses ASD-STE100 (Simplified Technical English): not the docs, not code
comments and not commit messages. Write them all in the same natural voice.

### An example

Too terse:

> Bifrost has one main window: a thin side bar on the left and a canvas filling the rest. On the
> canvas you arrange frames that overlap and snap together.

Better:

> Bifrost's interface is built around one main window, which holds a side bar on the left and a
> canvas for everything else. On the canvas, frames can overlap or snap together, and each frame
> shows a panel, such as a chat or the session list, or several panels stacked as tabs.

## Explainer pages

Big architecture pieces get a local HTML page in `docs/explainers/`: one self-contained file with
diagrams, opened in a browser. Use one only when a picture makes the idea clearer than text, for
example the canvas and panel model or how Bifrost talks to a Claude Code session. Don't make one
for a small feature, and link each page from the README.

Each page opens with a short contents list and ends with a glossary. The first use of a term in a
section links to its glossary entry, so a reader can look up a "frame" or a "hidden attach" in one
click. The glossary only covers terms specific to Bifrost (frame, stack, hidden attach, hold key)
or to Swift and macOS internals (main actor, responder chain, PTY). Everyday terms (window, focus,
chat) and Claude Code terms (session, agent view, rewind) don't need an entry.

A page ships with the work. A task that builds a big piece, such as Heimdall and modules, writes its
page in the same task, and a task that changes a piece with a page updates that page. Plans name
this as a step, so it isn't left for later.

## Where things go

| Folder | What |
| --- | --- |
| `docs/behaviour/` | What each feature does: the spec that tests prove |
| `docs/ports/*/DELIBERATE-DIFFERENCES.md` | Where the native app differs from Electron on purpose |
| `docs/explainers/` | HTML pages for the big pieces |
| `docs/specs/` | The architecture design (local only, not in git) |
| `docs/plans/` | Active plans only (local only, not in git) |
| `docs/hands-on-tests.md` | The list of things to check by hand in the real app |
| `docs/archive/` | Finished plans and phase records (local only, not in git) |

Plans and other docs written for agents (`docs/plans/`) can stay short and terse to save tokens,
as long as they lose no meaning. Code comments and commit messages use the same natural voice as the
docs, kept tight: one or two flowing sentences on what the code does and why, never a list of
fragments. In-app text stays friendly and plain.
