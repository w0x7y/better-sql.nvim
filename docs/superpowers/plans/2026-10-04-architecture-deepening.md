# Architecture deepening implementation plan

> For agentic workers: use executing-plans with independent work delegated through dispatching-parallel-agents. Run regression checks and review each result before integration.

**Goal:** Implement all four approved architecture improvements while preserving existing SQL and staged-edit behavior.

**Architecture:** Concentrate presentation mechanics in a grid module. Deepen existing statement and Table session modules, and remove the connection's dependency on the table renderer.

**Tech stack:** Lua, Neovim, Python, Psycopg and PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-10-04-architecture-deepening.md`.

## Global constraints

The spec's constraints apply to every task. Preserve the existing uncommitted QoL work. Make local changes without committing, pushing or modifying unrelated files.

## Task 1: Grid presentation

Files: create `lua/better_sql/grid.lua`; migrate `results.lua`, `table.lua` and the existing cell controls; add `tests/lua/test_grid.lua` and preserve rendering tests.

Interface: `grid.new(buf, options)` returns a view owning `render(columns, rows, options)`, `select(row, col)`, `selection()` and cell controls. Render accepts raw cell arrays and optional staged markers. Grid options define clipping, minimum width, reserved edit-marker width, sticky headers and selection notifications. Selection yields row/column indexes plus the raw cell and column name. No table-session state lives in grid.

- [x] Write regression coverage for Unicode, manual cursor movement, counted table movement, empty grids, sticky headers and detail cleanup.
- [x] Run `nvim --headless -u NONE -l tests/lua/test_grid.lua` and establish failure before implementation.
- [x] Implement shared behavior, migrate both views and remove duplicated geometry and interaction lifetime.
- [x] Verify result-cell, export and display tests, then real table rendering with PostgreSQL.

## Task 2: Profile lifecycle

Files: `connection.lua`, connection tests and renderer lifecycle callers. Keep table renderer edits with Task 1's owner.

Interface: connection operations accept an optional presentation choice adapter via configuration; production uses Neovim's chooser. Connection calls existing Table session lifecycle operations directly.

- [x] Add a failing test that exercises connection switching with staged cells and controlled choices without renderer function replacement.
- [x] Inject the choice at the existing Table session seam and migrate connection and test callers.
- [x] Remove renderer lifecycle forwarding after callers migrate.
- [x] Run connection lifecycle and delivery-race checks, preserving both staged-cell checks.

## Task 3: SQL lexical context

Files: `statement.lua`, `completion.lua`, statement/completion tests and a focused lexical-context test.

Interface: `statement.context(lines, row, col)` produces cursor state, selected statement, full tokens and cursor-prefix tokens with statement-relative byte offsets. Existing statement-selection behavior remains available; retire `normal_positions` once completion is migrated.

- [x] Write failing context tests with quoted names, partial tokens, strings, nested comments and statement offsets.
- [x] Implement one lexical analysis and migrate completion to the returned context.
- [x] Replace byte-mask assertions with behavior checks; preserve alias/set-operation tests.
- [x] Run statement and context tests, then completion checks against PostgreSQL.

## Task 4: Table session paging

Files: `table_session.lua`, `python/better_sql/tables.py`, paging tests. Leave renderer navigation delegation to Task 1's owner.

Interface: pages carry `page_size` and `next_offset` from the helper. Table sessions provide `next_page()` and `previous_page()`; recovery uses authoritative next offsets. Existing `load(offset)` remains for direct loading and filter/sort resets.

- [x] Write failing session tests for non-100 paging and hidden-row recovery, plus helper metadata assertions.
- [x] Add helper paging facts, session navigation and shared recovery traversal; delete Lua page-size constants.
- [x] Change renderer page commands to delegate to session navigation.
- [x] Run session and Python paging checks, then live paging integration tests.

## Final integration

- [x] Update `docs/architecture.md`, relevant README behavior and glossary concepts.
- [x] Run all Python unit/integration tests and all Lua scripts sequentially against disposable PostgreSQL.
- [x] Review the combined changes; fix important findings and rerun affected checks.
- [x] Run `git diff --check` and remove the temporary database.

## Verification results

All 32 Python unit tests, 51 PostgreSQL integration tests and 25 Neovim test scripts passed against disposable PostgreSQL 17.6. The full Lua suite passed again after the final split-window repaint fix. `git diff --check` passed. The temporary database was stopped and removed.

Independent review found that repainting shared grid buffers moved unrelated window selections. A regression reproduced the failure; preserving each window’s logical cell fixed it, including Unicode geometry changes. Focused review found no further issues. Connection tests also reproduced and fixed stale chooser callbacks and reentrant supersession.
