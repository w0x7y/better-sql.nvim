# State ownership

| Module | Owns | Interface used by callers |
| --- | --- | --- |
| `lua/better_sql/connection.lua` | Candidate activation, active profile, schema cache and operation completion | Connect, reconnect, refresh schema, read snapshots and subscribe to changes |
| `lua/better_sql/table_session.lua` | Staged cells, originals, paging, filter/sort settings and recovery across all grids | Create a session, browse/edit/save/reload, close and read snapshots |
| `lua/better_sql/grid.lua` | Cell geometry, selection, counted movement, sticky headers and raw-cell copy/detail lifetime | Render raw cells, read or change selection |
| `lua/better_sql/table.lua` | Table buffers, status and editing/filter/sort controls | Open a table session or render a preview |
| `lua/better_sql/results.lua` | Result buffers, status and selected result set | Show query output and switch result sets |
| `lua/better_sql/statement.lua` | SQL lexical state, statement boundaries and statement-relative tokens | Read one cursor context or select a statement |
| `lua/better_sql/schema.lua` | Schema-tree buffers and expanded nodes | Render connection snapshots or open a tree |
| `python/better_sql/tables.py` | Typed row originals, relation metadata, retention and atomic saves | `TableStore.page()` and `TableStore.save()` |

The [domain glossary](../CONTEXT.md) defines the terms used here. The Lua facade in `init.lua` wires commands to these modules. SQL completion reads the connection module's schema cache. Presentation snapshots are copies; callers cannot mutate owned originals, staged cells or catalog metadata through them.

Table sessions share a request queue for each helper because that helper has one row-original store. Each page request computes retained handles when it reaches the front of the queue. Other grids' visible rows and all valid staged originals remain retained. Closing a session skips its queued requests and completes its pending callback once. A renderer or callback failure releases the queue so another grid can continue.

Ordinary paging preserves the original version of a staged row. Reload explicitly recovers fresh handles by primary key, including staged rows hidden by a filter. Missing rows remain visible for review and discard. A save clears only the submitted cell values; edits staged while saving remain pending. A save with active criteria includes its refresh, blocks profile switching until completion, and reports a refresh failure separately from the committed edits.

The helper returns each page's requested `page_size` and nullable `next_offset`. Sessions use these facts for navigation and recovery; review rows appended after recovery do not change them. The table renderer delegates page movement to its session.

Table and result views adapt their snapshots to the shared grid. The grid uses display widths for layout and byte positions for Neovim cursors, while copying and inspecting cells preserves raw values. Selection reads the window receiving the action and rejects status/header rows. Table-specific editing and result-set selection remain in their respective views.

Completion consumes a single statement context containing cursor state, the selected SQL statement, full tokens and cursor-prefix tokens. Both token lists have statement-relative byte offsets and independent records for completion's scope annotations. Comments and quoted values share the same lexical rules as statement selection.

`TableStore.save()` accepts relation identity and staged edits, then validates them against privately retained metadata. Bound values and quoted identifiers produce typed updates guarded by `xmin`. It updates originals only after the transaction commits, so conflicts and deferred constraint failures leave originals available for retry.

Connection attempts check staged edits before starting and before activating a candidate. Superseded connects and schema refreshes complete once with structured errors. Helper exit clears the active cache and completes pending operations; late replies cannot restore obsolete state.

Connection lifecycle calls Table sessions directly. The optional `choose_pending_edits(resolve)` setup callback supplies the Save/Discard/Stay choice; Neovim's chooser is the default. Choices from superseded attempts are ignored before they can mutate staged edits.

The transport and PostgreSQL connection are the test seams. Session tests exercise state transitions without creating buffers, while UI and integration tests cover real Neovim rendering and PostgreSQL behavior. See the [development checks](../README.md#development-and-release-checks) for the full suite.
