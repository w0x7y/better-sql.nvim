# Architecture deepening

Implement the four opportunities in the architecture review approved by the user's instruction to implement all of them. Preserve the existing PostgreSQL editing workflows and the current QoL changes.

## Constraints

- Neovim 0.10 or newer and Python 3.10 or newer.
- No new runtime dependencies.
- Connection owns profile activation and the schema cache.
- Table session owns staged cells, row originals, shared request queues and recovery.
- The Python row-original store keeps typed metadata and atomic save behavior.
- Keep query results read-only, table cells staged until saved, and CSV exports limited to loaded data.

## Grid presentation

Add one grid presentation module that owns formatted column geometry, byte-span hit testing, selection, movement, copy/detail controls and cleanup. Results and Table session snapshots are its two data adapters. Keep result-set switching, table status, staged-cell markers, width policies and edit commands in their current owners. Both views support counted cell movement. Empty grids retain filter/sort controls. Selection is tracked in the actual window displaying the grid; actions from metadata cannot use a stale cell.

## Profile switching

Connect the connection module directly to Table session. Supply Save/Discard/Stay choices through a presentation adapter, with deterministic choices available to tests. Retire renderer forwarding calls and migrate every caller. Keep staged-cell checks before connection work and before activation, callback-once behavior, cancellation and reentrant protection.

## SQL lexical context

Make the statement module own one lexical analysis of cursor state, statement location and quoted tokens. Completion consumes full and prefix tokens from that analysis and retains alias scopes and catalog suggestions. Preserve byte offsets, cursor-prefix matching, comments, nested block comments, dollar quotes, escape strings, quoted identifiers and set-operation scopes. Retire the normal-byte-mask interface after migrating callers. Do not add caching or a configurable parser.

## Paging

Return authoritative paging facts from the Python helper and make Table session own next/previous navigation and recovery traversal. The renderer never calculates page offsets or assumes a helper page size. Keep the existing default of 100 rows; do not add page-size configuration. Recover hidden staged rows without advancing by display rows appended for review. Session tests cover non-100 page sizes to expose any remaining hidden invariant.

## Verification

Write meaningful regression tests before changing each behavior. Run the Lua rendering, lexical, connection, paging and recovery checks, then all Python and Neovim tests against a disposable PostgreSQL database. Review the combined implementation and update architecture documentation and the glossary for any new concepts.
