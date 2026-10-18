# Project Instructions

## Primary Instruction Source (Compact)

The single source of truth for all agent behavior, project conventions, gotchas, workflows, and decision-making is the si:

**`si/*.md`** (at the project root)

- This file is intentionally more compact than a traditional `AGENTS.md` to reduce token usage.
- **Always read `si/*.md`** at the start of any new session or before beginning a significant task / multi-step change.
- Treat the rules and knowledge in `si/*.md` as higher priority than general defaults.
- When the file is updated, re-read it before continuing work.
- The human reviews all proposed changes to this file via diffs.

## When Working

- Follow the Prime Directive checklist in `si/*.md`.
- Prefer minimal, style-matching diffs.
- Update `si/*.md` (and related docs) when new behaviors, gotchas, or workflows are discovered.
- Never commit operator artifacts (db files, scratch reports, etc.).
