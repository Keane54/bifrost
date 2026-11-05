# Project rules

Write all text for this project in ASD-STE100 Simplified Technical English. This applies at all times, to all of:

- The README and all other documentation.
- Code comments in the scripts.
- Commit message bodies.
- Responses in conversation about this project.

Exception: text that users read inside the app (dialogs, confirmations, tooltips, empty states, error messages) is plain, friendly English. It may ask a question, for example "Are you sure you want to delete this?". It must not sound robotic. Keep the facts exact (user decision, 2026-11-05).

Core rules of the specification:

- Use short sentences. Give one idea in each sentence.
- Use the active voice.
- Use approved words. Do not use figurative language, idioms, or invented nouns.
- Give one instruction in each sentence in procedures.
- Use a word as one part of speech only.
- Never use the em dash. Use the standard "-" character, or write separate sentences.

# Code rules

- Add a library only when a feature needs it. Name that feature in the plan.
- Write ESM TypeScript only. Do not write CommonJS.
- Run scripts as `.ts` files directly with Node 24 or later.
- Run scripts that load node-pty with `ELECTRON_RUN_AS_NODE=1 electron <file>.ts`.
- Build each className with cx(). Do not build a className with a template literal.
- Format and lint the code with Biome. Run `pnpm check` before each commit.
- Wrap commit body lines at 100 characters. commitlint refuses longer lines.

When you edit existing text, check that it conforms. If it does not conform, correct it.

# Test sessions

- Each test session has a name that starts with `bifrost-test-`.
- Each test session uses `--model haiku`.
- The directory of each test session is `.m0-sandbox/` in the repository.

# Safety rules

- Never send input, a signal, `claude stop` or `claude rm` to a session whose name does not start with `bifrost-test-`.
- The user has real sessions open on this Mac.
