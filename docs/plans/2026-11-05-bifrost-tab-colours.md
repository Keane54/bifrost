# Bifrost tab colours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** You can choose the text colour of each Overview tab from 12 colours, also red, amber and yellow. The box red and the box yellow stay shades that no other Overview colour comes near.

**Architecture:** The tab colour is already an index (`OverviewTab.color`) into the tokens `--color-tab-1` to `--color-tab-6`. This plan adds six tokens, a reducer action, and a colour row in Overview Settings. A theme test measures the distance in OKLab between each Overview colour token and the two box colours.

**Tech Stack:** React 19, Tailwind v4 tokens in `app.css`, Base UI, Vitest, Biome.

**Spec:** `docs/specs/2026-11-04-bifrost-design.md` (sections 8.3, 8.10, 8.12, 22).

## Global Constraints

- Write all prose, comments and commit bodies in ASD-STE100. Never use the em dash. Wrap commit body lines at 100 characters. Use Conventional Commits.
- Text that a person reads inside the app is plain, friendly English, not STE.
- Colours are tokens in `src/renderer/src/styles/app.css` only. No hex colour or `rgb(` in a `.ts` or `.tsx` file (the theme test enforces this).
- No purple or pink on the Overview (the user keeps purple for fleets). The existing theme test for this stays.
- Add no library.
- Implementers never use `git stash`, `git checkout --`, `git restore` or `git reset`.
- `pnpm test`, `pnpm typecheck` and `pnpm check` (0 warnings) pass.

## Review Focus

1. A saved Overview config with a colour index 0 to 5 keeps its colour after the change. An index of 12 or more, or a value that is not a whole number, falls back as before. Owner: Task 1 (`parseTab keeps a saved colour and refuses 12`).
2. A new tab gets an automatic colour from the first six (cool) colours only, so no tab turns red without a choice. Owner: Task 1 (`addTab cycles through the first six colours`).
3. Reset to default resets the columns and the filter. It keeps the name and the colour. Owner: Task 1 (`resetTab keeps the colour`).
4. A colour token that comes near a box colour later (for example a new amber) fails a test. Owner: Task 1 (`each Overview colour differs clearly from the box colours`).

## Decisions in this plan

| # | Decision | Reason |
|---|---|---|
| C1 | Reds, ambers and yellows are normal Overview colours. The box red (`#f5766d`) and the box yellow (`#e2b93b`) are reserved shades. Each token of the families `tab`, `prio`, `project` and `watch` has an OKLab distance of at least 0.10 from both box colours. | User decision, 2026-11-05: "any reds or yellows used for red or yellow boxes must be different from reds elsewhere". 0.10 in OKLab is about five steps that a person can see. |
| C2 | The amber `#f59e0b` (priority 1 and the watch colour amber) is 0.066 from the box yellow. It becomes `#d97706`. | C1. |
| C3 | Six new tab colours, indices 6 to 11: red `#e0443c`, amber `#d97706`, yellow `#fde68a`, lime `#a3e635`, white `#f2f2f2`, sky blue `#7dd3fc`. Each has a text contrast of at least 4 on both panel backgrounds (`#181818`, `#080808`). | The red is the lightest red that is still 0.10 from the box red. |
| C4 | The project icon colours stay blue and green. | The icon sits inside the box. A red icon in a red box is the worst clash. The user can ask for warm project colours later. |
| C5 | A new tab cycles through the indices 0 to 5 only. A colour comes from the user only. | No tab becomes red or yellow by chance. |

---

### Task 1: Tab colour choice and reserved box shades

**Files:**
- Modify: `src/renderer/src/styles/app.css`, `src/renderer/src/overview/config.ts`, `src/renderer/src/overview/cells.tsx`, `src/renderer/src/overview/OverviewSettingsPanel.tsx`, `docs/specs/2026-11-04-bifrost-design.md`
- Test: `test/renderer/theme.test.ts`, the config tests in `test/renderer/overview/`, the Overview Settings panel tests in `test/renderer/overview/`

**Interfaces:**
- Consumes: `OverviewTab.color`, `overviewReducer`, `resetTab`, `TAB_TEXT`, `useOverview` (M3).
- Produces:
  - `config.ts`: `TAB_COLOURS = 12`, `DEFAULT_TAB_COLOURS = 6`, a new action `{ type: 'setTabColour'; tabId: string; color: number }`. The reducer ignores a colour that is not a whole number from 0 to 11, and an unknown tab.
  - `cells.tsx`: `TAB_TEXT` has 12 entries (`text-tab-1` to `text-tab-12`). New `TAB_COLOUR_NAMES: readonly string[]` with 12 names, in index order: `Cyan`, `Light blue`, `Green`, `Teal`, `Blue`, `Mint`, `Red`, `Amber`, `Yellow`, `Lime`, `White`, `Sky blue`. Add `TAB_SWATCH: string[]` with the 12 full `bg-tab-N` class names.
  - `app.css`: `--color-tab-7` to `--color-tab-12` with the values of C3. `--color-prio-1` and `--color-watch-amber` become `#d97706` (C2). Update the comment above the tab tokens: the first six are the automatic colours; the others you choose; no token comes near the box colours.

Rules:
- `parseTab`: a whole number from 0 to 11 stays. Else the fallback is `index % DEFAULT_TAB_COLOURS`.
- `addTab`: `color: (n - 1) % DEFAULT_TAB_COLOURS`.
- `resetTab` does not change `color` or `name`.
- Overview Settings: a row "Colour" below the "Tab" row. It shows 12 square swatches (about 14 px) in one line that may wrap. It is a radio group: `role='radiogroup'` with `aria-label='Tab colour'`, and each swatch is a `button` with `role='radio'`, `aria-checked`, and `aria-label` from `TAB_COLOUR_NAMES`. The chosen swatch has a 1 px `text-strong` outline. A click calls `update({ type: 'setTabColour', tabId: tab.id, color })`. Left and right arrow keys move the choice (wrap at the ends) and the focus. Square corners. No new colour value in `.tsx`.

- [ ] **Step 1: Write the failing tests**

Theme test (`test/renderer/theme.test.ts`), with a small OKLab helper in the test file:
- `each Overview colour differs clearly from the box colours`: for each `--color-(tab|prio|project|watch)-*` hex token, the OKLab distance to `box-red` and to `box-yellow` is at least 0.10. The failure message names the token and the distance.
- `each tab colour is readable on both panels`: for `tab-1` to `tab-12`, contrast at least 4 on `#181818` and `#080808`.
- `defines 12 tab colours`: `tab-1` to `tab-12` exist.
- Keep `the Overview colour tokens have no purple or pink` (it now also covers `tab-7` to `tab-12`).

Config tests:
- `parseTab keeps a saved colour and refuses 12`: colours 0, 5 and 11 stay. 12, -1, 1.5 and `'3'` give `index % 6`.
- `addTab cycles through the first six colours`: tabs 7 and 13 (by `nextTab`) get colour 0.
- `setTabColour sets the colour of one tab`, and `setTabColour ignores a bad colour or an unknown tab` (12, -1, 2.5, `tabId: 'none'` give the same config object).
- `resetTab keeps the colour`: a tab with colour 8 and changed columns, after `resetTab`, has colour 8 and the default columns.

Panel test:
- `the Colour row shows 12 swatches and marks the tab colour`: 12 `role=radio` items with the names; the one at the tab colour has `aria-checked=true`.
- `a click on a swatch sets the tab colour`: a click on `Red` gives the active tab colour 6, and the tab text in the Overview tabs uses `text-tab-7`.
- `arrow keys move the choice`: Right on `Sky blue` goes to `Cyan`.

- [ ] **Step 2: Run the tests and see them fail**

Run: `pnpm vitest run test/renderer/theme.test.ts test/renderer/overview`
Expected: FAIL. The distance test names `prio-1` and `watch-amber` (0.066).

- [ ] **Step 3: Implement the tokens, the action, the lists and the Colour row**

- [ ] **Step 4: Change the spec**

- 8.3: the tab line says you can choose the text colour of each tab from 12 colours. The icon line keeps "a palette without yellow, red and grey" (C4).
- 8.10: replace "Yellow, red and grey have fixed meanings ... only as a translucent row background (section 8.12)" with: the box yellow, the box red and the parked grey are reserved shades. Other Overview colours can be red, amber or yellow, but each differs clearly from the box shades (OKLab distance 0.10 or more; a test checks it). Keep the purple line.
- 22: add one line for C1 to C5 (user decision, 2026-11-05).

- [ ] **Step 5: Run all checks and the build**

Run: `pnpm test && pnpm typecheck && pnpm check && pnpm exec electron-vite build`
Expected: PASS, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/styles/app.css src/renderer/src/overview test/renderer docs/specs/2026-11-04-bifrost-design.md
git commit -m "feat(overview): choose the text colour of each tab" \
  -m "Overview Settings has a Colour row with 12 colours, also red, amber and yellow." \
  -m "The box red and the box yellow are reserved shades. A test checks that each other" \
  -m "Overview colour differs clearly from them. The amber is now darker for that reason."
```
