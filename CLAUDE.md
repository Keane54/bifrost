# Bifrost native

The native Swift app. The Electron app is a behaviour reference only: build features the Swift and
AppKit way, never as a copy of the TypeScript code.

- Docs follow `docs/WRITING.md`: brief, humanised, explainer pages only for big architecture.
- Code comments and commit messages use ASD-STE100. No em dash. Lines of 100 characters or less.
- In-app text is friendly, plain English.
- Run tests through `scripts/run-sandboxed.sh`; the full gate is `scripts/check.sh`.
