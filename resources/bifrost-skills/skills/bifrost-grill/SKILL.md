---
name: bifrost-grill
description: Grill the user one question at a time to clear up an ambiguous feature request or plan. Use when the user asks to be grilled, or wants to develop a feature in detail before work starts. Not for small questions.
disable-model-invocation: false
---

# Grill

The goal is a shared, clear understanding of the goals between you and the user, before the work
starts. Ask questions until no open branch is left.

## The decision tree

Map the feature as a tree of decisions. Each decision opens the decisions that depend on it. You
can ask about a decision once the decisions that it depends on are settled. Never guess at an
answer that you have not heard yet.

## One question at a time

Ask one question at a time, then wait for the answer. Each answer can settle, open or close other
branches. Update the tree, then pick the next question: the open decision that blocks the most
other decisions.

Format each question like this:

```text
**Q4. <short title>**

<The question. Give the options when there are some.>

Recommended: <your answer, and the main reason for it>
```

Each question has a recommended answer. Word the question so that "yes" accepts it. Keep it short
and plain.

## Facts are your job

Find facts yourself. Read the code, the docs and the existing plans before you ask. Never ask the
user for something that you can look up. Ask the user only for decisions.

For a wide search, use a subagent so that the files do not fill this conversation. While it runs,
you can ask a question that does not depend on its result.

## Write each answer into the plan

Write each answer into the plan or design document of the feature: the one that this session made
or will make. Write it as soon as the user answers. Put the decision and its reason in the right
section of the document. Do not copy the conversation.

If no such document exists, make one in the place that the project uses for plans. Look at the
project instructions and the existing files to find that place. If it is not clear, ask the user.

## The end

The grilling ends when no open branch is left: each decision has an answer, and nothing is
assumed in silence. Then list the decisions in a few lines and ask the user to confirm the shared
understanding. Do not start the work until the user confirms.

If the user stops early, mark the open decisions as open in the document.
