# Rules for text that a person reads

These rules remove the common signs of AI writing from PR review comments, PR replies, short docs
and chat text. When you write, avoid each pattern. When you rewrite, remove it.

A language model picks the choice that fits the widest range of readers. A person writes for one
reader and one subject, so their choices are uneven and specific. Each pattern below is one form of
the default choice.

## Always

- Each sentence adds something that the reader does not already have, from earlier in the text or
  from the conversation around it.
- No note that Claude, an AI or a tool wrote the text. No sign-off. No filler praise. See
  pattern 21.
- Never use the long dash (the em dash) or the en dash. See pattern 8.
- Use British spelling in prose: organise, colour, behaviour. Keep code, names and quotes as they
  are.

The patterns are in order, strongest first. Patterns 1 to 5 justify an edit on one sighting. A
pattern marked "weak alone" needs other signs in the same passage before you act on it.

## A. Staging instead of stating

### 1. Not X but Y

Watch for: "not X but Y", "not just X, but Y", "it's not X, it's Y", "X rather than Y", the same
contrast split over two sentences ("This does not mean X. It means Y."), and a clipped negative
tail (", no guessing").

The negative half names something that no one claimed, so that the positive half sounds bigger.
State the point directly. Keep a contrast only when the negative half corrects a belief that the
reader really holds, or when both halves carry information.

- Before: "It's not just a refactor. It changes how the cache expires."
- After: "This also changes how the cache expires."
- Before: "The options come from the selected item, no guessing."
- After: "The options come from the selected item, so the user does not have to guess."

### 2. One-line closers and dramatic fragments

Watch for: a one-sentence paragraph that repeats the paragraph before it; "That is the real win.";
"That distinction matters."; "Let that sink in."; the same closer after several sections; a
sentence after an example that names what it showed ("This shows the importance of..."); a row of
fragments ("No config. No setup."); a word in capitals or with full stops between words for stress.

The line asks the reader to pause on a claim instead of adding to it. Cut a closer that repeats.
Keep a short sentence when it adds a new fact or consequence. Merge a row of fragments into one
sentence with a specific claim.

- Before: "No config. No setup. It just works."
- After: "It works without a config file or any setup."

### 3. Sayings that sound deep

Watch for: "the real question is", "at its core", "what really matters", "fundamentally", "the
heart of the matter", "X is the Y of Z", "X becomes a trap", "the language of", "the currency of".

An ordinary point is dressed as a hidden truth. Replace the saying with the specific claim.

- Before: "The real question is whether teams can adapt. At its core, what really matters is
  organisational readiness."
- After: "The question is whether teams can adapt. That mostly depends on whether the organisation
  is ready to change its habits."

### 4. A run-up before the point

Watch for: "Let's dive in", "Let's break this down", "Here's what you need to know", "Here's the
thing", "Quick note", "Heads up", "Honestly?", "Look,", "Real talk".

The writer announces the point, or stages a moment of candour, instead of making the point. Remove
the run-up. "Honestly" inside a casual sentence is normal. The sign is a standalone opener before a
routine claim.

- Before: "Quick note: here's the thing about this hook. It runs on every render."
- After: "This hook runs on every render."

### 5. Arguing with no one

Watch for: "To be clear", "I'm not saying", "Don't get me wrong", "This is not to say", "A tempting
approach would be", "One might be tempted to", "You might think... but", "It would be easy to just".

The text answers an objection, or rejects an option, that appears nowhere else. Remove the defence.
If it holds a real claim, state the claim. Keep an objection that someone really raised, and an
option that the reader would really weigh.

- Before: "Session tokens rotate every 24 hours. A tempting approach would be to rotate them with a
  cron job that restarts the auth service, but that would drop every active session. Rotation
  happens in place, and clients refresh transparently."
- After: "Session tokens rotate in place every 24 hours, and clients refresh transparently."

## B. Rhythm by rule

### 6. Forced groups of three

Ideas come in threes to sound complete, whether the meaning has three parts or not. It can be three
words, three parallel examples, or three short facts followed by a lesson. Check that each item
adds a distinct idea. If not, merge the items or develop the strongest one. Keep three items when
the meaning has three.

- Before: "The event features keynote sessions, panel discussions, and networking opportunities.
  Attendees can expect innovation, inspiration, and industry insights."
- After: "The event includes talks and panels. There's also time to meet people between sessions."

### 7. Repeated sentence openings

Several sentences in a row start with the same subject. Merge them, change the subject, or start
with the action. Do not ban the word: one sentence can still start with it.

- Before: "This function reads the file. This function then parses it. This function returns the
  result."
- After: "This function reads the file, parses it and returns the result."

### 8. Dashes

Never use the long dash (the em dash) or the en dash as punctuation, and never a double hyphen in
their place. Use a full stop, a comma, a colon or brackets, or rewrite the sentence. A dash lets the
writer skip the choice of how two clauses relate, so a model uses it everywhere. Leave hyphens in
code, commands, paths, URLs and compound words alone.

- Before: "The new policy -- announced without warning -- affects thousands of workers."
- After: "The new policy, announced without warning, affects thousands of workers."

### 9. Stacked qualifiers (weak alone)

Watch for: "could potentially", "might arguably", "it's also possible that", "in some cases it
may", "to be fair".

Qualifier after qualifier makes every claim sound unsure. Keep a qualifier only when the doubt is
real and the meaning needs it. Keep scope limits, safety notes and real corrections. "Perhaps" and
"tends to" are normal.

- Before: "It could potentially be argued that the change might have some effect on start-up time."
- After: "The change may affect start-up time."

### 10. Hyphenated pairs after the noun (weak alone)

Keep the hyphen before a noun ("a well-known bug") and drop it after the noun ("the bug is well
known"). Words that always take a hyphen, such as third-party, keep it everywhere.

### 11. Passive voice and missing subjects (weak alone)

The text hides who acts, or drops the subject. Use the active voice when it makes the actor clear.

- Before: "No config file needed. Results are saved automatically."
- After: "You do not need a config file. The app saves the results automatically."

## C. Inflation and borrowed authority

The fact underneath is usually sound. Keep it and remove the dressing.

### 12. Overused AI words

Watch for: actually, additionally, align with, bolster, crucial, deep dive, delve, enhance,
garner, highlight (verb), interplay, intricate, key (adjective), landscape (abstract), meticulous,
pivotal, quietly, robust (figurative), showcase, tapestry, testament, underscore (verb), valuable,
vibrant.

Models use these words far more often than people do, often in groups. Use the plain word or cut
it. A formal word outside this list is not a sign by itself.

- Before: "Additionally, this PR enhances the error handling, showcasing a more robust approach."
- After: "This PR also improves the error handling."

### 13. Inflated significance

Watch for: "plays a key role", "a pivotal moment", "marks a shift", "underscores the importance",
"reflects a broader", "sets the stage for", "the evolving landscape", "the future looks bright",
"exciting times ahead", "a step in the right direction".

An ordinary detail is said to mark a change, prove a legacy or promise a future. Keep the fact and
drop the significance. End on the last concrete fact.

- Before: "This PR moves the last service to TypeScript, marking a pivotal moment for the codebase
  and setting the stage for future growth."
- After: "This PR moves the last service to TypeScript."

### 14. Vague connections

Watch for: "associated with", "connected to", "in connection with", "linked to", "tied to".

The text says that two things are connected, but not how. Name the relation. If you do not know
it, keep the vague word.

- Before: "The flaky test is tied to the retry logic, which adds a random delay."
- After: "The retry logic adds a random delay, which makes the test flaky."

### 15. Shallow -ing phrases

Watch for: highlighting, underscoring, emphasising, ensuring, reflecting, symbolising, contributing
to, fostering, showcasing.

An -ing phrase is added to a simple fact to make it sound deeper. Keep the fact. Keep the -ing
phrase only when it states something true that the reader can check.

- Before: "The function now returns early on empty input, ensuring robustness and improving
  maintainability."
- After: "The function now returns early on empty input."

### 16. Sales language

Watch for: seamless, powerful, effortless, cutting-edge, groundbreaking, renowned, stunning,
breathtaking, "a rich set of", "a diverse array of", "commitment to".

The text reads like an advert. State what the thing is and what it does.

- Before: "The new CLI offers a seamless, powerful way to manage your config."
- After: "The new CLI reads and writes your config."

### 17. Borrowed authority

Watch for: "experts say", "it is widely known", "industry reports", "many developers agree", and
"best practice" with no reason.

A vague authority stands in for the reason. When you know the real source and what it said, name
it. Otherwise give the reason itself, or cut the claim.

- Before: "Best practice is to avoid global state here."
- After: "Global state here lets two tabs overwrite each other's filters."

### 18. Avoiding is, are and has

Watch for: "serves as", "stands as", "functions as", "acts as", "boasts", "features", "offers",
"represents".

Simple verbs are replaced with longer phrases. Use is, are and has.

- Before: "This module serves as the entry point and features three exports."
- After: "This module is the entry point and has three exports."

## D. Formatting by rule

The sign is decoration on every item.

### 19. Bold as decoration

Words are in bold for no reason, and each list item has a bold label and a colon. Remove the bold.
Turn a labelled list into prose when the labels carry no information of their own.

- Before:
  - **Performance:** Performance is better with the new cache.
  - **Security:** Security is stronger with the input checks.
- After: "The new cache makes it faster, and the input checks make it safer."

### 20. Decorative headings

Watch for: headings in Title Case; emojis or arrows on headings and list items; a horizontal rule
between each section; a top heading that repeats the title.

Use sentence case. Remove the decoration and the horizontal rules. Let a heading name what its
section holds. Use straight quotes unless the target uses curly ones (weak alone).

- Before: "## Key Changes And Improvements"
- After: "## Changes"

## E. Leftovers from the chat and the draft

Remove these outright.

### 21. Chatbot residue

Watch for: "Great question!", "Great catch!", "You're absolutely right", "Of course!",
"Certainly!", "I hope this helps", "Happy to help", "Let me know if...", "Would you like me to...",
"Here is a...", a sign-off or a name at the end, and a note or footer that says an AI wrote it.

A chatbot's greeting, praise, offer or sign-off is left in text that should stand on its own. It is
the surest sign in this list. Remove the wrapper and keep the content. Keep praise only when it
names a specific thing.

- Before: "Great catch! You're absolutely right, the index is off by one. I've fixed it now. Let me
  know if you have any other questions!"
- After: "The index was off by one. Fixed now."

### 22. Guesses and knowledge limits

Watch for: "as of my last update", "based on the available information", "it is believed that", and
"likely" or "probably" used to fill a gap.

The text admits that it has no source, then fills the gap with a guess. Say what you checked and
what you did not check, or cut the sentence. Never present a guess as a finding.

- Before: "This likely causes a memory leak in production."
- After: "The listener is added on each mount and never removed."

### 23. A heading repeated in the first sentence

A heading is followed by a sentence that restates it, such as "## Performance" and then "Speed
matters.". Remove that sentence.

### 24. Writing about the text instead of its subject

Watch for: what the text or code replaced ("was added to replace"); how it was made ("generated
from", "compiled from"); a layout that the reader can see ("the table below shows").

Mention an earlier version only in a changelog, release notes or a migration guide. A code comment
says what the code does now, not its history. Keep a caveat that changes what the reader should do.

- Before: "This function was added to replace the old loop over all items, which was O(n^2)."
- After: "This function uses a map for O(1) lookups."

## F. Writing for the wrong reader

### 25. Re-explaining what the reader knows

A model writes for a reader who shares no context. A reply in a PR thread has a reader who already
knows the background. Act on this pattern when you can see the conversation, or when the text is
clearly a reply.

Watch for: a short reply that restates the problem, walks through the diagnosis and lays out the
evidence before it reaches the decision; proof that a plan will work; background that the other
person wrote; the answer in the last line.

Lead with the decision. Keep only the reasoning that would change whether the reader agrees:
usually one fact that they lack, and any link that they need to act. The full diagnosis belongs in
the ticket or the follow-up PR.

- Before: "Yeah, you're right, this works around the issue rather than fixing it. The real fix is in
  `MergeService`: when we move a child under a new parent, it should update `pipeline_id` along
  with `parent_id`. We can backfill the bad rows from the audit log. I checked QA: 123 past
  merges, only 6 rows wrong now, so the cleanup is small.
  Since `MergeService` is shared, I'd rather open a separate ticket than widen this PR."
- After: "Agreed, this is a workaround. I'd rather keep this PR small and open a separate ticket for
  the `MergeService` fix and the backfill. `MergeService` is shared code, so a fix here means
  checking the merge flow for every account."

## When not to act

- Leave a pattern alone inside a quote, a title or a name, or in text that talks about the phrase.
- Keep the greeting and sign-off of a letter or email that the user wrote.
- Keep the details that carry the writer's voice: a specific detail, mixed feelings, a real aside,
  a first-person choice that the writer can explain.
- A person can make any one of these choices on purpose. Several signs together are the safeguard.

## Voice

- If the user gives a sample of their writing, match its sentence length, word choice, punctuation
  and openings. The dash rule (8) still applies.
- Without a sample, take the voice from the kind of text. PR comments, replies and docs are plain
  and direct, like a note from a colleague. Chat and personal writing can keep opinions, humour and
  asides.
- When the patterns are gone, the text must still sound like a person. Vary the sentence length.

The patterns come from the Wikipedia page "Signs of AI writing" (WikiProject AI Cleanup).
