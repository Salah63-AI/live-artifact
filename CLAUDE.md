# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this folder is

A working folder, not a codebase: there is nothing to build, lint or test.

It is a git repo pushed to the **public** GitHub repo `Salah63-AI/live-artifact` (branch `main`). `.gitignore` keeps `personal-os - template/` out, because its vault holds private notes and a CV; never add it. Commits use the repo-local identity `Salah63-AI` with the GitHub noreply email.

The Supabase project for this folder is **live artifact** (ref `laiyvalsyzetqylouhkc`, region eu-central-1, URL `https://laiyvalsyzetqylouhkc.supabase.co`), in org "Tradex". Use it through the Supabase connector. Free-tier projects pause when idle; restore it before use if its status is INACTIVE. Only the publishable key may appear in committed files (the page uses it); any secret or service key goes in a git-ignored `.env`.

- `personal-os - template/` is the main project, a Claude-driven "Personal OS" (Obsidian vault + skills + brand). Read its own `CLAUDE.md` before working inside it; its rules apply there (soul.md voice, no em-dashes, never modify `vault/sources/`, update `vault/index.md` and `vault/log.md` after vault writes).
- Loose deliverables sit at the root (see below).

## Personal OS architecture (what spans files)

- Three layers: `vault/sources/` is immutable raw input; the rest of `vault/` is a wiki Claude maintains; `CLAUDE.md` + `soul.md` are the schema.
- Flow: files dropped in `inbox/` are processed by `/ingest` into vault pages. The SessionStart hook in `.claude/settings.json` prints `soul.md` and counts inbox files. It is a bash command, so on Windows it depends on Git Bash.
- `brand/config/brand-config.md` is the source of truth for Tradex output styling: teal `#47BD9B`, black (never white) text on teal, Calibri, EGP currency. The logo is `brand/images/tradex-logo.png`.
- Automations go in `work/<n>-<name>/` (none exist yet). Schedules are listed in `scheduler/schedule.md` and applied by `/cron-setup`.
- Project skills live in `.claude/skills/`: `setup`, `ingest`, `lint`, `new`, `status`, `brand`, `cron-setup`, `venture-sync`.

## Root deliverables

`tradex-flow.html` is a single-file app (logo inlined as a data URI, supabase-js from jsDelivr) for Tradex's estimate-to-billing flow. **Supabase is the source of truth**: the page signs in with email + password, then reads and writes the tables below. Editing a step, adding a project or logging a month happens in the page, not in the HTML.

Database (`public` schema). Each migration applied to Supabase is mirrored as `supabase/migrations/<version>_<name>.sql`, using the version Supabase assigned (see `supabase_migrations.schema_migrations`); `supabase/seed.sql` holds the starting phases and steps. When changing the schema, apply it with `apply_migration` and add the matching file. Keep editor emails out of these files, since the repo is public.
- `phases` (`is_loop` marks the monthly cycle drawn as the loop) and `steps` (ordered by `position` within a phase; `short_label` is the two-line diagram label).
- `projects` and `progress_entries` (one row per project per month, `period` = first of month). The view `progress_summary` computes `cost_pct`, `gap_pts`, `needs_review` (gap > 10 pts) and `invoice_amount` = (final % minus the highest earlier final %) × contract value.
- `cost_items` (price list: `kind` is `material` or `subcontractor`, unique `code`; material items must have `material_group` = `installation` | `accessories` | `fittings`, subcontractor items must not).
- `location_zones` (`central` 100%, `medium` 125%, `far` 150%; editable `factor_pct`).
- `estimates` (header: `name` shown as "Project name", `customer`, `sales_person`, `location`, `zone`; rates `overhead_pct` 15, `indirect_pct` 25, `margin_pct` 20, `marketing_amount` EGP, `discount_pct`, `vat_pct` 14; optional `project_id`), `estimate_units` (indoor unit types with `quantity`) and `estimate_lines` (cost of ONE unit at central prices; `unit_price` is copied from the price list when added, so price list edits never move a saved estimate).
- Views `estimate_unit_summary` and `estimate_summary` do all the math, and the page's `calc()` mirrors it for the live build-up (keep them in step):
  - direct = (material + subcontractor) × zone %; overhead and indirect are % of direct; total cost = direct + overhead + indirect + marketing;
  - sales price = total cost / (1 − margin %); discount = % of sales price; net = sales − discount; VAT = net × vat %;
  - margin = net − total cost, `margin_pct_actual` = margin / net.
- `change_log`: the `log_change()` trigger records every insert, update and delete on all nine data tables above with full old and new rows (keyed by `id`, or `code` for zones), so any change can be traced or restored from SQL.
- `quote_settings` (one row: the rates public quotes use, `max_discount_pct`, `public_enabled`) and `quote_requests` (requests sent from the public page, with the visitor's lines in `payload` and the server-calculated prices in `quoted`).
- Access: RLS allows everything only to signed-in users whose email is in `editors` (checked by `private.is_editor()`). `anon` has no table grants at all. The only things `anon` can do are four `security definer` functions, which Supabase's advisor flags on purpose: `public_price_list()` (active items, no prices), `public_zones()` (no factors), `public_quote(p)` (returns prices only, enforces the discount limit) and `submit_quote_request(p)` (recalculates the price server-side and inserts a request). Never add a price, cost, rate or margin to what these return. To add an editor: `insert into public.editors (email) values ('name@example.com');` (lower case).

`tradex-quote.html` (Vercel path `/quote`) is the public quote page: no sign-in, it only calls the four public functions, keeps a draft in localStorage, and shows sales price, discount, net, VAT and total. Requests and the public rates are managed in the estimator's "Quote requests" tab, which can turn a request into a normal estimate at today's prices.

`tradex-estimate.html` (Vercel path `/estimate`) is the cost estimator, built the same way and sharing the sign-in. Its workspace has three sections (project details with the zone choice, indoor units with lines grouped by cost group, rates and pricing) and a sticky price build-up; details and rates save when a field is left. It loads SheetJS from cdnjs for the Excel/CSV price list import and the Excel export, which writes live formulas (with cached values) rather than hardcoded totals. Its footer says "Built by Salah Agent".

The diagram in `drawSchematic()` is generated from the data: non-loop steps are spaced along the straight pipe and loop-phase steps are spread around the circle.

### Design versions (`designs/`)

**The live pages now use design B.** They were built from `designs/b/*.html` with the live database URL and key, `workspace.css` inlined into the page `<style>`, the logo inlined as a data URI, and links renamed to the `tradex-*.html` files. The earlier live design is git tag `v1`. To change the look, edit the live page directly (it is self-contained); `designs/b` stays as the sandbox copy. `designs/a/` ("Guided": top bar, step-by-step wizard, dark price readout, cooling blue and copper, Barlow) and `designs/b/` ("Workspace": dark sidebar, master-detail estimator with Alt+1/2/3 section tabs and Enter-to-next-cell, dense tables, Source Sans 3) each hold `flow.html`, `estimate.html` and `quote.html`. They are copies of the live pages with the same JS; each keeps the original inline `<style>` and layers its design on top (`a/guided.css`, `b/workspace.css`, plus a small page `<style>`), and wraps base functions (`renderSummary`, `renderPrice`, `openEstimate`, `showTab`, `renderEditor`) instead of rewriting them. Fixes to page logic must be made in the live page and in both copies.

Both designs use a **sandbox** Supabase project, not the live data: `designs/config.js` points them at project ref `qgyminfoernzixjtjaoe` (the org's default project, eu-west-1). It has the same schema (the same migration files applied in order), the seed flow, the sample `SMP-` price list and its own `editors` and auth users. Schema changes must be applied to both projects. Vercel: `/a` and `/b` redirect to each design's estimator.

Two older static copies no longer track the data: the Claude Design canvas https://claude.ai/artifact/3S4691ZojzG8JNMHuZkaj6 and the dashboard https://claude.ai/artifact/68ruvgkjzP7YtsybZaFnwj.

## Environment

- Windows 10. PowerShell is the primary shell.
- `python3` is not runnable, so the odoo-tools MCP server cannot start and the scheduler guide's `which python3` step fails.
- `gh` is logged in as `Salah63-AI` (repos `live-artifact`, `Personal-Portfolio`).
- Supabase is reachable through the connector, not the CLI (which isn't installed). The org "Tradex" has two projects: live artifact (live data) and the default project, now the design sandbox. Free projects pause when idle; restore before use.
- Local preview: `.claude/launch.json` serves the folder with `python -m http.server 3000` (port 3000 matches the Supabase Site URL); open pages by file path, e.g. `/designs/a/estimate.html`.
