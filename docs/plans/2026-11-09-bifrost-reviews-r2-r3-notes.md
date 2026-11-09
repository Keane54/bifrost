# Reviews R2 and R3: notes from R1

R1 (the read-only Reviews panel) merged into `main` on 2026-11-09 (`05583ea`). The R1 reviews found these points for the R2 and R3 plans. Read them before you write those plans.

## Must do in R2 or R3

| Item | Why |
|---|---|
| Write a handled item with `lastReplyAt ?? at`, never a null `lastReplyAt`. | `splitWork` never reopens an item with a null `lastReplyAt`, so a "No action" item would not come back after a new trusted comment. |
| Page the review threads of one PR on demand before a request round. | The poll reads only the newest 20 threads (`reviewThreads(last: 20)`). `isTruncated(pr)` and the per-list flags show a cut list. |
| Fetch the review list of one To review PR on demand for a re-review. | To review rows load no reviews, threads or comments (poll cost). The re-review needs the commit of your last submitted review. |
| Count a re-request only for a direct request. | A team row loses its pause when any team gets a new request event (`watcher.ts` re-request rule with the team `requestedAt`). |
| Log a repeating partial GraphQL error only when its message changes. | Today it logs once for each poll, about 720 lines a day at 2 minutes. |
| Use one shared list of model choices. | The list is in two settings checks and in `ReviewsSection.tsx`. |

## Can wait

- `reviewRequests(first: 10)` has no `pageInfo`. More than 10 requests on one PR can hide the viewer's request.
- `timelineItems(last: 10)` can miss the viewer's request event on a busy PR. The time then falls back to `createdAt`, and the baseline rule can treat a new request as old.
- `turnedOnAt` stays after a turn-off. Requests made while Watch GitHub was off flash at the next turn-on (capped notifications).
- The pause and poll choices in `ReviewsSection.tsx` repeat the settings checks. Export them from `src/shared/settings.ts`.
- The Reviews state store makes no backup of a state file with a later version, and no test covers a failed write.
- Renderer: two `useReviews` subscriptions (side bar and panel); no keyboard access to rows; no arrow keys on the tabs; the failed-check cross has no accessible text; `hotTab` has no test.
- `test/renderer/background.test.ts` and `test/scripts/icon.test.ts` run near the 5 s default timeout on a loaded Mac.

## Related

- [Reviews design](../specs/2026-11-09-bifrost-reviews-design.md)
- [R1 plan](2026-11-09-bifrost-reviews-r1.md)
