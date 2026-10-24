# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this folder is

A working folder, not a codebase: there is nothing to build, lint or test.

It is a git repo pushed to the **public** GitHub repo `Salah63-AI/live-artifact` (branch `main`). `.gitignore` keeps `personal-os - template/` out, because its vault holds private notes and a CV; never add it. Commits use the repo-local identity `Salah63-AI` with the GitHub noreply email.

The Supabase project for this folder is **live artifact** (ref `laiyvalsyzetqylouhkc`, region eu-central-1, URL `https://laiyvalsyzetqylouhkc.supabase.co`), in org "Tradex". Use it through the Supabase connector. Free-tier projects pause when idle; restore it before use if its status is INACTIVE. Keys go in a git-ignored `.env`, never in committed files.

- `personal-os - template/` is the main project, a Claude-driven "Personal OS" (Obsidian vault + skills + brand). Read its own `CLAUDE.md` before working inside it; its rules apply there (soul.md voice, no em-dashes, never modify `vault/sources/`, update `vault/index.md` and `vault/log.md` after vault writes).
- Loose deliverables sit at the root (see below).

## Personal OS architecture (what spans files)

- Three layers: `vault/sources/` is immutable raw input; the rest of `vault/` is a wiki Claude maintains; `CLAUDE.md` + `soul.md` are the schema.
- Flow: files dropped in `inbox/` are processed by `/ingest` into vault pages. The SessionStart hook in `.claude/settings.json` prints `soul.md` and counts inbox files. It is a bash command, so on Windows it depends on Git Bash.
- `brand/config/brand-config.md` is the source of truth for Tradex output styling: teal `#47BD9B`, black (never white) text on teal, Calibri, EGP currency. The logo is `brand/images/tradex-logo.png`.
- Automations go in `work/<n>-<name>/` (none exist yet). Schedules are listed in `scheduler/schedule.md` and applied by `/cron-setup`.
- Project skills live in `.claude/skills/`: `setup`, `ingest`, `lint`, `new`, `status`, `brand`, `cron-setup`, `venture-sync`.

## Root deliverables

`tradex-project-flow.html` is a self-contained page (step data and logo inlined) showing Tradex's estimate-to-billing flow in 9 steps. Two online copies must be updated by hand whenever steps, owners or tags change:

- Claude Design canvas: https://claude.ai/artifact/3S4691ZojzG8JNMHuZkaj6 (one artboard, `project/Main.dc.html`)
- Dashboard: https://claude.ai/artifact/68ruvgkjzP7YtsybZaFnwj (step data is an attached JSON file referenced by `datasets/steps`; replace the file and update that record)

## Environment

- Windows 10. PowerShell is the primary shell.
- `python3` is not runnable, so the odoo-tools MCP server cannot start and the scheduler guide's `which python3` step fails.
- `gh` is logged in as `Salah63-AI` (repos `live-artifact`, `Personal-Portfolio`).
- Supabase is reachable through the connector, not the CLI (which isn't installed). The org "Tradex" also has an unused default project, which is paused.
