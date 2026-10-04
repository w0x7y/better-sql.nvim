# PostgreSQL editing in Neovim

The plugin connects SQL buffers, schema browsing and staged table edits to PostgreSQL.

## Language

**Connection profile**:
A named set of PostgreSQL connection settings. One profile is active at a time.
_Avoid_: Database profile

**Relation**:
A PostgreSQL table, partitioned table or view identified by its schema and name. A relation can be browsed even when its cells are read-only.

**Table session**:
The browsing and editing lifecycle for one relation under one connection profile. Its table grid displays the current page and staged cell values.

**Grid**:
A view of rows and columns with one selected cell. Query-result grids show loaded query values; table grids also show staged replacements.

**SQL statement**:
A unit of SQL selected at the cursor. Semicolons inside quoted values or comments do not split statements.

**Row original**:
The primary key and database version captured when an editable row is loaded or successfully saved. Saving compares that version to detect concurrent changes.
_Avoid_: Row cache

**Staged cell**:
A replacement cell value awaiting an explicit save. SQL NULL and an empty string are distinct values.
_Avoid_: Unsaved row
