# Draft rules

These rules apply to each draft of the daily update. The draft is in the voice of the user, not
in the style of these rules.

## Secrets

- Never put a secret in a draft or in the result. A secret is, for example, a token, a password,
  a key, or a link that holds one. This rule comes before all other rules in this file.

## Format

- Follow the template exactly: its title, its headings and their order. Copy each line of the
  template as it is, with its `**` marks. Add no heading. Do not change or remove a heading.
- The first line of the template is the title. Each bold line after it is a heading. Write the
  text of each part on the lines below its heading. Write nothing above the title.
- Keep each blank line of the template. Put a blank line between two parts only when the
  template or the examples have one there.
- Write plain text below each heading. Use a list only for separate items. A list item starts
  with `- `.
- Use standard Markdown, and only two forms of it: `**text**` for bold and `- ` for a list item.
  A paste into Slack shows `**text**` as bold, but it shows `*text*` and `_text_` as italic. So
  never use one star or an underscore for bold.
- No underline: a Slack message has no underline. Do not use `#` headings, tables, code blocks,
  quotes or HTML.

## Voice

- Write in the voice of the examples. Use their greeting, their words, their length and their
  tone. Write a greeting only when the examples have one.
- With no examples, write in the first person, in a plain and friendly voice.
- Say what the work means for the team. Do not give ticket numbers or ticket states. The same
  applies to PR numbers. For example, write "refunds in checkout are now in review", not
  "PAY-101 moved to In review".
- Look forward when the input shows a next step, for example a review, a release or a
  handover.
- Keep the draft short: one to three sentences, or a short list, below each heading.
- Never add a note that Claude, an AI or a tool wrote the draft.

## Truth

- Never state work that the input does not show. Use only the items of the area of the draft.
  Do not add work, dates, people or results.
- When the input shows no blocker and no risk, the answer below the blocker heading is
  "Nothing", or the word that the examples use for it.
- A short answer such as "Nothing" or "Yes" is a full answer. Add no text to it.
- When the input supports no text for a heading, for example no next step for a heading such
  as "Next", write one short and plain line. Use the words that the examples use in this case,
  or "Nothing". Never invent a plan.
- An area with no items still gets a draft. Below the heading for the work that moved, say in
  one short sentence that nothing moved since the last update. The user adds the rest.

## Example

This example shows the form, with the default template and no examples. When the input has
examples, take the voice from them, not from this example.

The items of the area: the ticket "Add refunds to the checkout API" moved from In progress to In
review, and the PR "Add the refunds endpoint (PAY-101)" merged.

```text
**Daily update**
**Done since my last update**
I merged the refunds endpoint, and refunds in checkout are now in review.
**Next**
The refunds change goes through review next.
**Blocked or at risk**
Nothing
```
