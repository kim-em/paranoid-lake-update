#!/usr/bin/env bash
# Called by `paranoid-lake-update ... --notify` when an audit is not CLEAN.
# Runs in the output directory; PLU_OUT, PLU_STATUS, PLU_TITLE, PLU_VERDICTS are set.
# Replace the body with whatever reaches you (Zulip, mail, a desktop notification...).
set -euo pipefail
inbox="${HOME}/paranoid-lake-update-flagged"
mkdir -p "$inbox"
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) status=$PLU_STATUS $PLU_VERDICTS"
  echo "title:  $PLU_TITLE"
  echo "output: $PLU_OUT"
} >> "$inbox/log.txt"
cp SUMMARY.md "$inbox/$(date -u +%Y%m%dT%H%M%SZ)-SUMMARY.md"
