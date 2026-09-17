# Cues search: speed and accuracy improvement plan

## Objective

Make automatic voice-driven search feel useful in a live class: cards should
arrive quickly, be correct often enough to trust, and be rare enough not to
interrupt the teacher.

This plan intentionally focuses on speed and usefulness. Security and privacy
hardening are out of scope for this iteration.

## Current pipeline

`finalized speech -> mention detector -> LinkResolver -> Cues card`

The default detector is a precision-oriented heuristic. An optional
Foundation Models detector produces richer candidates but is currently much
noisier. Resolution currently blocks card display on thumbnail fetching and
the product-site path waits before beginning its Wikipedia fallback.

## Success criteria

Track these metrics against replayable fixtures before changing behavior and
after each milestone.

| Metric | Definition | Initial target |
| --- | --- | --- |
| Detection precision | Correct detected mentions / all detected mentions | >= 70% |
| Detection recall | Correct detected mentions / expected mentions | Improve without violating the noise budget |
| Retrieval top-1 accuracy | First result is the intended result / detected mentions | >= 80% |
| Helpfulness | Cards opened or sent / cards shown | Establish baseline, then improve per kind |
| Noise budget | Explicitly dismissed or known-wrong cards | <= 1 per 10 minutes of class time |
| Latency p50 | Final speech result to usable card | < 800 ms |
| Latency p95 | Final speech result to usable card | < 2 s |

`Open` and `Send` are positive usefulness signals. `Dismiss` is a strong
negative signal. Do not infer that an unopened card was wrong: the teacher may
simply be busy.

## Phase 1: Establish a repeatable benchmark

### Work

1. Create sanitized, checked-in fixtures containing short transcription
   excerpts, expected mentions, expected kinds, expected top result, and
   explicit no-suggestion cases.
2. Include the phrases that matter most in real use:
   - books, tools, products, fonts, people, places, topics, videos, quotes,
     and word definitions;
   - transcription errors, Indian English, mixed-language speech, and
     classroom-management chatter;
   - ambiguous terms and generic nouns that must not create a card.
3. Add detector tests that assert expected mention keys and kinds.
4. Add resolver tests using saved API responses or injectable source clients;
   tests must not depend on live network results.
5. Instrument locally useful non-content timing and outcome metrics:
   detection duration, source latency, fallback use, result rank, card
   display, open/send/dismiss, and no-result count.

### Acceptance criteria

- One command runs detector and resolver fixtures deterministically.
- The report provides current precision, recall, top-1 accuracy, p50/p95
  latency, and per-kind outcomes.
- Existing behavior has a recorded baseline before tuning begins.

## Phase 2: Reduce time-to-card

### Work

1. **Decouple thumbnail loading from card creation.** Return a text-only card
   as soon as its source result is valid; fetch and attach its thumbnail in a
   background task that updates the displayed card if it succeeds.
2. **Start independent resolution paths concurrently.** For named things,
   begin official-site validation and Wikipedia lookup together, then select
   the best valid card. The current implementation awaits the site attempt
   before starting Wikipedia.
3. **Set a fast-path policy.** If the preferred source has not produced a
   quality result after roughly 1–1.5 seconds, allow a valid fallback to win
   instead of waiting for the whole request timeout.
4. **Add a bounded local result cache.** Cache successful normalized mentions
   and cards with a TTL. Repeated mentions in one lesson should resolve nearly
   immediately; consider a small persistent cache only after session caching
   is validated.
5. **Track source health.** Maintain recent latency and failure statistics per
   source, and prefer fast reliable sources for a given mention kind.

### Acceptance criteria

- Thumbnail fetching does not affect the time at which the card is visible.
- A slow or failed preferred source cannot delay a valid fallback beyond the
  p95 target.
- Repeated mentions resolve from cache in under 100 ms.
- Fixture results are functionally unchanged except where an explicitly
  improved ranking is expected.

## Phase 3: Improve candidate and result accuracy

### Architecture

Make the three stages explicit and independently testable:

1. **Candidate extraction** — heuristic and optional model candidates.
2. **Local validation and scoring** — transcript grounding, kind validation,
   deduplication, and confidence calculation.
3. **Source-specific retrieval and ranking** — fetch results and choose the
   best card or an ambiguity set.

### Work

1. Keep the heuristic detector as the high-precision default.
2. Use the Foundation Models detector as a secondary candidate generator when
   no strong heuristic cue fires or the heuristic candidate is incomplete or
   ambiguous. Do not allow it to replace a strong heuristic result by default.
3. Require every candidate to be grounded in the new transcript span. Build
   enriched search terms from verified spoken tokens plus a small local
   type-specific vocabulary rather than relying on unconstrained model wording.
4. Create one shared result score using:
   - entity/title similarity;
   - kind compatibility;
   - source reliability for the kind;
   - query specificity;
   - transcription and candidate confidence;
   - optional historic teacher acceptance for comparable results.
5. Add targeted normalization for likely ASR variation in brands, book titles,
   and names. Prefer aliases and token similarity to brittle exact-title rules.
6. Keep dictionary cards behind explicit definition/explanation cues.
7. For a high-confidence result, show one immediate card. For a genuinely
   ambiguous result, show two compact choices rather than one confidently
   incorrect card.

### Acceptance criteria

- The benchmark reaches the top-1 and noise targets without lowering recall
  below the documented baseline.
- Every emitted candidate has a traceable transcript span and score.
- Ambiguous fixture cases return either a ranked choice set or no card, never
  an arbitrary single result.

## Phase 4: Learn from teacher interactions

### Work

1. Record local per-kind outcomes for cards: shown, opened, sent, dismissed.
2. Add an optional lightweight `Useful` / `Not useful` control for a tuning
   period; it should be quicker than writing feedback.
3. Build local preferences such as a teacher's preferred source for books,
   videos, and named tools.
4. Use interaction signals to adjust ranking thresholds, not to silently
   train an unconstrained global model.
5. Re-run fixtures after every threshold, heuristic, prompt, or ranker change.

### Acceptance criteria

- Ranking can use local teacher preference where it materially improves a
  result.
- Changes are rejected if they improve recall but exceed the noise budget.
- A dashboard or report can compare the latest run with the baseline.

## Suggested implementation order

1. Build fixtures, deterministic source-client fakes, and metrics.
2. Move thumbnail loading off the critical path.
3. Parallelize named-thing resolution, add timeout policy, then add the
   session cache.
4. Extract candidate validation/scoring into a dedicated type and add
   transcript grounding.
5. Add result ranking and ambiguity presentation.
6. Add local interaction feedback and preference-aware ranking.

## Files likely to change

| Area | Primary files |
| --- | --- |
| Pipeline orchestration and timing | `App/Cues/CuesController.swift` |
| Candidate extraction and validation | `App/Cues/MentionDetector.swift`, `App/Cues/FoundationModelsDetector.swift` |
| Retrieval, concurrency, caching, ranking | `App/Cues/LinkResolver.swift` |
| Card state / async thumbnail updates | `App/Cues/CueCard.swift`, `App/Cues/ThumbnailLoader.swift` |
| Feedback and display | `App/Cues/CueCardView.swift`, `App/Cues/CuesRailBlock.swift` |
| Automated regression suite | New Cues fixture and test target files |

## Guardrails for implementation

- Do not change several quality dimensions at once without a benchmark run;
  keep each change attributable.
- Preserve the fast heuristic path while experimenting with the model path.
- Prefer no card to a low-confidence card once the noise budget is exceeded.
- Keep source clients injectable so tests do not become dependent on live APIs.
- Ship each phase behind measurable acceptance criteria rather than perceived
  improvement alone.
