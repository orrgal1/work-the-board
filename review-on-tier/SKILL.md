---
name: review-on-tier
description: "Launch a dedicated code review agent on an operator-chosen tier (1-3), same model provider as the current session, and keep it open for iterative review discussion until the operator is satisfied. Use for 'tier 1/2/3 review' requests."
---

# Review On Tier

Launch one review subagent at the requested tier, on the current session's provider, inside this session — no new tab or terminal. Keep it alive so the operator can iterate.

## 1. Get the tier

Use the tier (1, 2, or 3) the operator gave. If none was given, ask — never default.

## 2. Resolve provider + model

Identify the current provider (anthropic, openai-codex, deepseek, google-antigravity) from the active model, then look up `provider/model:effort`:

|Tier|Anthropic|OpenAI|DeepSeek|Gemini|
|---|---|---|---|---|
|3|`anthropic/claude-fable-5-1:high`|`openai-codex/gpt-6-astra:high`|`deepseek/deepseek-v4-flash:max`|`google-antigravity/gemini-3.8-flash:high`|
|2|`anthropic/claude-opus-5:high`|`openai-codex/gpt-5.6-sol:high`|`deepseek/deepseek-v4-flash:high`|`google-antigravity/gemini-3.8-flash:medium`|
|1|`anthropic/claude-sonnet-5:high`|`openai-codex/gpt-5.6-luna:high`|`deepseek/deepseek-v4-flash:low`|`google-antigravity/gemini-3.8-flash:low`|

Tier is model strength at high effort where the provider has three models; fewer models → step the effort within the levels that model actually supports. Unrecognized provider → ask the operator instead of guessing.

## 3. Launch the review subagent

`task` can't pin a specific provider/model, so run a real `omp` subprocess instead of opening a tab or terminal. Give it a concrete target (diff, PR number, branch, or file set) and what to check (correctness, security, quality, spec adherence) — never a bare "review this". `--mode json` emits JSONL — redirect it to a file, or the whole stream lands in your own context:

```bash
out=$(mktemp /tmp/review.XXXXXX.jsonl)
omp -p --model "<provider>/<model>:<effort>" --mode json "<review request>" > "$out"
session_id=$(jq -r 'select(.type=="session") | .id' "$out")
jq -r 'select(.type=="turn_end") | .message.content[] | select(.type=="text") | .text' "$out"
```

## 4. Iterate, then stop

On operator feedback (challenge a finding, re-check after a fix, narrow or widen scope), resume that same session — never start a fresh one:

```bash
omp -p --model "<provider>/<model>:<effort>" --mode json -r "$session_id" "<feedback>" > "$out"
jq -r 'select(.type=="turn_end") | .message.content[] | select(.type=="text") | .text' "$out"
```

Stop resuming once the operator says the review is done — nothing to tear down.
