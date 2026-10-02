# State ownership

| Module | Owns | Interface used by callers |
| --- | --- | --- |
| `lua/better_sql/connection.lua` | Candidate activation, active profile, schema cache and operation completion | Connect, reconnect, refresh schema, read snapshots and subscribe to changes |
| `lua/better_sql/table_session.lua` | Staged cells, originals, paging, filter/sort settings and recovery across all grids | Create a session, browse/edit/save/reload, close and read snapshots |
| `lua/better_sql/table.lua` | Buffers, keymaps, cursor positions and cell rendering | Open a grid or render a preview |
| `lua/better_sql/schema.lua` | Schema-tree buffers and expanded nodes | Render connection snapshots or open a tree |
| `python/better_sql/tables.py` | Typed row originals, relation metadata, retention and atomic saves | `TableStore.page()` and `TableStore.save()` |

The [domain glossary](../CONTEXT.md) defines the terms used here. The Lua facade in `init.lua` wires commands to these modules. SQL completion reads the connection module's schema cache. Presentation snapshots are copies; callers cannot mutate owned originals, staged cells or catalog metadata through them.

Table sessions share a request queue for each helper because that helper has one row-original store. Each page request computes retained handles when it reaches the front of the queue. Other grids' visible rows and all valid staged originals remain retained. Closing a session skips its queued requests and completes its pending callback once. A renderer or callback failure releases the queue so another grid can continue.

Ordinary paging preserves the original version of a staged row. Reload explicitly recovers fresh handles by primary key, including staged rows hidden by a filter. Missing rows remain visible for review and discard. A save clears only the submitted cell values; edits staged while saving remain pending. A save with active criteria includes its refresh, blocks profile switching until completion, and reports a refresh failure separately from the committed edits.

`TableStore.save()` accepts relation identity and staged edits, then validates them against privately retained metadata. Bound values and quoted identifiers produce typed updates guarded by `xmin`. It updates originals only after the transaction commits, so conflicts and deferred constraint failures leave originals available for retry.

Connection attempts check staged edits before starting and before activating a candidate. Superseded connects and schema refreshes complete once with structured errors. Helper exit clears the active cache and completes pending operations; late replies cannot restore obsolete state.

The transport and PostgreSQL connection are the test seams. Session tests exercise state transitions without creating buffers, while UI and integration tests cover real Neovim rendering and PostgreSQL behavior. See the [development checks](../README.md#development-and-release-checks) for the full suite.
