# Project rules

Write all text for this project in ASD-STE100 Simplified Technical English. This applies at all times, to all of:

- The README and all other documentation.
- Code comments in the scripts.
- Commit message bodies.
- Responses in conversation about this project.

Core rules of the specification:

- Use short sentences. Give one idea in each sentence.
- Use the active voice.
- Use approved words. Do not use figurative language, idioms, or invented nouns.
- Give one instruction in each sentence in procedures.
- Use a word as one part of speech only.
- Never use the em dash. Use the standard "-" character, or write separate sentences.

When you edit existing text, check that it conforms. If it does not conform, correct it.

# Test sessions

- Each test session has a name that starts with `bifrost-test-`.
- Each test session uses `--model haiku`.
- The directory of each test session is `.m0-sandbox/` in the repository.

# Safety rules

- Never send input, a signal, `claude stop` or `claude rm` to a session whose name does not start with `bifrost-test-`.
- The user has real sessions open on this Mac.
