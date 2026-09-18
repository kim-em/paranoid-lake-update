# paranoid-lake-update

See what `lake update` would pull in **before** you run it, and have a human or an AI
look for malicious code in the diffs.

## Why

`lake update` clones the new revision of every dependency and then *executes* each
dependency's `lakefile.lean` to configure it. Later the Lean compiler runs code from
them at elaboration time (`run_cmd`, `#eval`, `initialize`, `@[extern]`, custom
targets, ...). A malicious upstream commit therefore runs on a developer's machine, or
in a CI runner holding tokens, before anyone has looked at it.

This tool predicts the update using nothing but `git`: bare clones, no checkout, no
hooks, and no Lake. It writes the complete diff of every dependency that would change,
flags high-risk files and suspicious added lines, and can hand the result to an AI
auditor and publish it as a gist or PR comment.

Only the Python standard library, `git`, and (for publishing) `gh` are needed.

## Commands

```
paranoid-lake-update plan      [--dir .] [--extra URL@OLD..NEW]...      # what would `lake update` do?
paranoid-lake-update compare   --base origin/master [--head REF]         # manifest at REF vs working tree / another REF
paranoid-lake-update compare   --old-manifest A --new-manifest B
paranoid-lake-update range     --repo URL [--from OLD] --to NEW           # any repository, any two revisions
paranoid-lake-update watch     --repo URL --branch main [--state FILE]    # new commits since the last run
paranoid-lake-update audit     --out DIR --audit claude|codex|pi|command  # (re)run an auditor on existing output
paranoid-lake-update publish   --out DIR [--gist] [--comment-pr N]
paranoid-lake-update prompt    --out DIR [--inline]                       # print the prompt for your own model
```

Every producing command (`plan`, `compare`, `range`, `watch`) accepts the audit and
publish flags too, so one invocation can do everything:

```
paranoid-lake-update plan --audit claude --audit codex --gist
```

### What `plan` replays

Lake (`Lake/Load/Resolve.lean`, `updateAndMaterializeCore`) materializes each direct
dependency at the head of its `inputRev`, visiting the root's `require`s in reverse
order (the order they appear in the manifest). After each package is materialized, the
entries of *its* `lake-manifest.json` are recorded for names not seen yet, and
transitive dependencies are materialized at those recorded revisions. First name seen
wins. `plan` replays exactly that from bare clones. It also reports when a direct
dependency's `lean-toolchain` differs from the root's, because `lake update` would then
bump the toolchain too.

What it cannot see: a `require` added to a dependency's lakefile that is not yet
reflected in that dependency's manifest. Use `compare` after the fact (base branch vs
update PR) for an exact answer; that is what the CI integration does.

### Output directory

```
SUMMARY.md            table of packages, links to upstream commits and GitHub compare views,
                      high-risk files, watchlist hits, non-fast-forward warnings, audit verdicts
plan.json             the same, machine-readable
diffs/<pkg>.diff      full `git diff old new`
diffs/<pkg>.log       header, commit list with authors and dates, diffstat
prompt.md             the prompt given to the auditor (after `audit`/`prompt`)
audit-<agent>.md      each auditor's report
comment.md            the PR comment body (after `publish`)
```

By default output goes to a fresh directory under `~/.cache/paranoid-lake-update/runs/`;
bare clones live under `~/.cache/paranoid-lake-update/repos/`.

### Auditors

| `--audit` | runs | notes |
|---|---|---|
| `claude` | `claude -p` with only `Read`, `Grep`, `Glob` | If `ANTHROPIC_API_KEY` is set but a Claude login exists, the key is dropped so the subscription is used; `PARANOID_KEEP_ANTHROPIC_API_KEY=1` keeps it. |
| `codex` | `codex exec --sandbox read-only` | `-o` captures the final message; the transcript is kept in `.codex-transcript.txt`. |
| `pi` | `pi --print` | needs `--model`; `--pi-provider` defaults to `openrouter`; `--inline` also passes `--no-tools`. |
| `command` | `--command 'your program'` | prompt on stdin, cwd is the output directory. Plug in anything. |

`--model` picks the model, `--agent-args` appends raw flags, `--prompt-file` replaces the
built-in prompt (placeholders `{summary}`, `{diff_dir}`, `{file_list}`), `--prompt-extra`
appends to it, and `--inline` embeds every diff in the prompt for models without file
tools.

The prompt asks for a Markdown report ending in `VERDICT: CLEAN`, `SUSPICIOUS` or
`MALICIOUS`, and tells the model to treat diff contents as untrusted data.

Exit status: `0` clean or no audit requested, `1` a verdict of SUSPICIOUS or MALICIOUS,
`3` an auditor produced no verdict, `2` usage or git error. `--notify CMD` runs a shell
command whenever the status is not `0` (with `PLU_OUT`, `PLU_STATUS`, `PLU_TITLE`,
`PLU_VERDICTS` in its environment), which is what makes `watch` usable from cron.

### Publishing

`--gist` uploads the summary, prompt, diffs, logs and audit reports as a secret gist
(`--gist-public` for a public one; files over ~950 KB are left out with a note).
`--comment-pr N [--github-repo OWNER/REPO] [--run-url URL]` posts the summary, gist and
artifact links, every audit report in a collapsed block, and the prompt in another, so
anyone can rerun the audit with their own model. `--dry-run` writes `comment.md` and
stops.

## Mathlib CI

`examples/mathlib-update_dependencies.patch` shows the steps added to Mathlib's hourly
`update_dependencies.yml`: after `lake update`, run `compare --base origin/master`
(plus `--extra` for the `mathlib-ci` pin that the same PR bumps), upload the output as
a workflow artifact, and once the PR exists, comment on it. The comment links every
upstream commit and GitHub's `old...new` compare view, so no gist or extra secret is
needed; reviewers run the AI audit locally with
`paranoid-lake-update compare --base origin/master --audit claude` in a checkout of
the PR branch, which is the command quoted in the comment.

## Watching a repository (e.g. Tau Ceti)

```
paranoid-lake-update watch --repo https://github.com/TauCetiProject/TauCeti --branch main \
    --audit claude --notify 'mail -s "TauCeti audit: $PLU_VERDICTS" you@example.org < SUMMARY.md'
```

The first run records the branch head; each later run audits `last..head` and advances
the recorded revision only when an auditor returned a verdict (so a crashed run is
retried next time). `examples/systemd/` has a user timer that runs this hourly.

## Tests

`tests/run.sh` builds toy upstream repositories with a planted exfiltration script and
an elaboration-time `IO.Process.run`, then exercises every command with a shell
auditor. No network and no AI needed.
