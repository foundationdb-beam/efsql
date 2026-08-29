# efsql TUI plan

A full-screen terminal UI replacing the current line-based CLI
(`Efsql.Cli`), focused on **data discovery**: "but really, what's in my
database?" The tool stays strictly read-only — all writes, migrations, and
application work remain in ecto_foundationdb proper.

## Goals

- Full-screen TUI on the modern Erlang terminal stack (OTP 28 raw mode),
  no NIFs, no external TUI dependency.
- Navigate the FDB directory hierarchy (storage_ids → tenants) and activate
  a tenant into the working session.
- Discover "table schemas" from the data itself — field names, inferred
  types, presence rates, indexes — despite there being no hard schema.
- Autocomplete throughout: SQL keywords, tenants, tables, fields,
  meta-commands.
- Friendly, Elixir-style rendering of Erlang/Elixir terms everywhere.

## Non-goals

- No writes of any kind (see Read-only guarantees).
- No general SQL expansion as part of this work — the TUI drives the
  existing `Parser -> Rewrite -> Planner -> Executor` pipeline as-is.
- Not a dashboard/monitoring tool; no cluster status/ops features.

---

## 1. Terminal substrate (OTP 28)

Verified against the installed OTP 28.3:

- **Raw mode**: the release runs with `-noshell`; at startup call
  `:shell.start_interactive({:noshell, :raw})` (exported since OTP 26;
  raw-mode reads matured through 28). Set `:io.setopts(:standard_io,
  [:binary])`.
- **Input**: in `{:noshell, :raw}` mode, `:io.get_chars("", 1024)` returns
  as soon as *any* data is available — one blocked reader process turns
  bytes into key events. A small decoder maps bytes to events: printable
  chars, control chars (`^C ^D ^L` …), and CSI escape sequences
  (`\e[A`…`\e[D` arrows, Home/End/PgUp/PgDn/Delete, `\e[Z` shift-tab).
  A ~50 ms Esc-disambiguation timer distinguishes a lone Esc press from an
  escape sequence prefix. (OTP master adds `io_ansi:scan/1` that does this
  decoding for us — our decoder is a thin module we can delete when we
  adopt that OTP release.)
- **Output**: plain ANSI writes from a single writer process: alternate
  screen `\e[?1049h` / `\e[?1049l`, hide/show cursor `\e[?25l` / `\e[?25h`,
  absolute addressing `\e[{row};{col}H`, SGR styling (via `Owl.Data` tags,
  which we already depend on). Full-frame repaint per event — at our screen
  sizes diffing is unnecessary.
- **Size**: `:io.columns()` / `:io.rows()` each frame (cheap; also serves
  as resize detection, since BEAM doesn't surface SIGWINCH).
- **Teardown**: `try/after` restores the main screen and cursor on any
  exit, including crashes — never leave the terminal corrupted.
- **Fallback**: on a non-tty stdin, raw mode returns `{:error, :enotsup}`
  (verified). Detect via `:io.getopts(:standard_io)` (`terminal: false`)
  and fall back to the current line-based REPL, which we keep as
  `Efsql.Cli`. This preserves piping (`echo 'select ...' | efsql`) and CI
  use.

**Spike first**: milestone 0 is a throwaway loop proving raw reads, escape
decoding, alt-screen painting, and clean restore inside the mix release on
macOS Terminal/iTerm/tmux — before any app code depends on it.

## 2. Architecture

The Elm architecture (TEA), because it keeps everything testable without a
terminal:

```
event (key/resize/task-result) -> update(model, event) -> model' -> view(model') -> frame
```

Processes:

- **InputReader** — blocked on `:io.get_chars/2`, sends decoded key events
  to the app.
- **App loop** (GenServer) — owns the `Model`, runs `update/2`, paints via
  the single-writer `Screen`.
- **Workers** — every DB touch (query, tenant list, discovery sampling) is
  a supervised `Task`; the result comes back as an event. The UI never
  blocks on FDB; in-flight work shows a spinner and stays cancellable
  (Ctrl-C cancels the task, second Ctrl-C exits).

Modules (pure cores separated from tty edges):

```
lib/efsql/tui.ex             entry: terminal setup/teardown, fallback selection
lib/efsql/tui/event.ex       byte -> key-event decoder            (pure)
lib/efsql/tui/screen.ex      frame painting primitives            (tty edge)
lib/efsql/tui/app.ex         Model + update/2                     (pure)
lib/efsql/tui/view/*.ex      per-mode views: model -> iodata      (pure)
lib/efsql/session.ex         active tenant, caches (schemas, completions)
lib/efsql/discover.ex        source enumeration + schema sampling (pure w/ injected reads)
lib/efsql/complete.ex        completion engine                    (pure)
lib/efsql/render.ex          term rendering rules                 (pure)
```

Testing: `update/2` is exercised with synthetic key events;
views get golden-frame tests (`view(model)` rendered to a string and
asserted); `discover`/`complete`/`render` get plain unit tests. Only the
milestone-0 spike needs a human at a real terminal.

## 3. Modes (screens)

One persistent status bar (cluster file, active storage_id/tenant, row
limit, key hints) + one active mode.

**Browse-first**: the tool opens in the Navigator; activating a tenant
lands in the Schema browser. Querying is a drill-down from what you're
looking at (`Enter` on a source or field pre-fills a statement) or one
keypress away (`q`) — the SQL pipeline is the engine, not the front door.

### 3.1 Navigator — pick your tenant

The entry mode; reachable anytime (`\t` or a key).

- Column browser over the FDB directory hierarchy, read via
  `:erlfdb_directory.list/2`: **root → storage_ids → tenants**. This
  matches ecto_fdb's layout exactly (DirectoryTenant: root node prefix
  `0xFE`, one directory per storage_id — default
  `"Ecto.Adapters.FoundationDB"` — containing one directory per tenant).
- Arrow/j-k navigation, type-to-filter, Enter descends / activates.
- Activating a tenant sets it in `Session` (guarded by
  `Tenant.exists?` + `Tenant.open` exactly as `qall` does today) and kicks
  off background discovery (3.3) to warm the completion cache.
- Directories that aren't ecto_fdb storage_ids still show up (it's the
  shared FDB directory layer) — annotate entries that contain openable
  tenants vs. plain directories, and show tenant counts.

### 3.2 Query — the drill-down REPL

The current REPL behaviors carried into a full-screen pane, reached from
the Schema browser (pre-filled statements) or directly with `q`:

- Multi-line editor with cursor movement, kill/yank basics, and
  history (up/down through past statements; persisted to
  `~/.efsql_history`).
- Results pane below: `Owl.Table` for row sets (as today), scrollable
  (PgUp/PgDn) instead of the current `limit+1` truncation trick; row count
  and elapsed time in the footer.
- Enter on a row opens the **Inspector** (3.4).
- Meta-commands stay (`\?`, `\set limit`, `\tenants` becomes the
  Navigator); `\plan` toggles the physical-plan overlay (reusing the
  `access`/`ops` debug rendering).
- Statements run against the session tenant, so bare `select id from
  users;` works — tenant-qualified names remain supported.

### 3.3 Schema — discovery from data

The heart of the tool. Per active tenant:

**Source (table) enumeration** — there is no catalog, so discover sources
from the keyspace itself: hop distinct key prefixes with key selectors —
read the first key in the tenant's data keyspace, unpack its tuple to get
the source name, seek to `strinc(source_prefix)`, repeat. O(#sources)
round trips regardless of table sizes. Cross-check against the metadata
keyspace (sources that have indexes) so indexed-but-empty tables still
appear.

**Schema sampling** — per source, sample bounded row sets (first N + last N
+ a few key-selector-spaced probes in between, default N=100, all within
snapshot reads and well under the 5 s transaction limit):

- field name → presence % (fields are per-object in FDB, so absence is
  signal, not error)
- inferred type histogram per field (utf8 binary / raw binary / integer /
  float / boolean / map / list / DateTime / NaiveDateTime / Versionstamp /
  nil) — a field can be polymorphic; show the split rather than a lie
- 2–3 example values per field (rendered per §5)
- primary-key shape from the raw key tuples (plain id vs
  `{partition, versionstamp}` tuples)
- indexes from `Metadata.transactional` (already used by the planner):
  index name, fields, in-progress (partial) status

The view is a two-pane browser: sources on the left (with sampled-row
counts), the field table on the right. `Enter` on a field pre-fills a
query (`select <field> from <table> limit 15;`). A visible caveat line:
"sampled N rows — not exhaustive". `r` re-samples with a larger N.

**Cache persistence**: discovery results are cached in `Session` (they
also power autocomplete) and persisted to `~/.efsql/cache/`, keyed by
`{cluster_file, storage_id, tenant, source}` and stored as plain Elixir
terms (versioned, discarded on format change). A persisted schema loads
instantly on the next session with its `sampled at <time>, N rows` line
shown prominently — staleness is visible, and `r` re-samples on demand.
Discovery is never triggered automatically for warm-cached sources.

### 3.4 Inspector — one row, fully

Any row from any result set: full-screen, pretty-printed per §5, with the
raw FDB key tuple shown alongside, j/k field navigation, `y` to copy a
value's textual form (OSC 52), Esc back.

## 4. Autocomplete

Tab-completion with a small popup (fuzzy prefix match, arrow/Tab cycling):

- **Context detection** drives the candidate set, using `SQL.Lexer` on the
  text left of the cursor (the parser we already ship): after `select` /
  in a predicate / after `order by` → field names of the statement's table
  from the discovery cache; after `from` → `tenant.table` pairs (tenants
  from the Navigator cache, tables from discovery); statement start →
  keywords + meta-commands; after `\` → meta-commands.
- Keywords track exactly what the pipeline supports (`select from where
  and between like not in order by asc desc limit`) — autocomplete is also
  how users learn the supported surface.
- Cold cache: completing on a table not yet sampled triggers background
  discovery for it; the popup fills in when the event lands.
- The engine is pure (`complete(text, cursor, session_caches) ->
  [candidates]`) and unit-tested against awkward partial statements.

## 5. Value rendering — Elixir-style

One module (`Efsql.Render`) used by every pane:

- Base: `inspect(term, pretty: true, syntax_colors:
  IO.ANSI.syntax_colors(), width: columns, limit: ..., printable_limit:
  ...)` — the same look as IEx.
- Above `inspect`, domain-aware rules:
  - printable UTF-8 binaries as strings; non-printable binaries as
    `<<0x1F, ...>> (23 bytes)` with a hex preview, never a wall of bytes
  - `EctoFoundationDB.Versionstamp` tuples rendered via `to_integer/1`
    with the raw form one keypress away (Inspector)
  - DateTime/NaiveDateTime/Date/Time via their `Inspect` impls (sigil
    forms)
  - nested maps/lists elided in table cells (`%{...}` / `[...]` with
    sizes), fully expanded in the Inspector
- Table cells truncate with `…`; the Inspector never truncates.

## 6. Read-only guarantees

- The TUI issues only reads: `Repo.all` / `all_range` / `async_*` through
  the existing executor, `:erlfdb_directory.list`, snapshot `get_range`
  reads for discovery, and `Metadata.transactional` (reads with a version
  check).
- One known write-shaped edge: `Tenant.open` runs ecto_fdb's open path
  (migration check; `Efsql.Repo.migrations/0` is `[]`). We keep today's
  `exists?`-guarded open so nothing is ever created, and we never call
  `Tenant.open!`/`create`. A true `open_readonly` in ecto_fdb is
  **deliberately deferred** — the guarded open is sufficient for now.
- No delete/clear/set APIs are linked anywhere in the TUI modules; a test
  asserts the TUI module tree has no references to writing Repo/erlfdb
  functions (cheap tripwire against regressions).

## 7. Milestones

Each lands independently; the line CLI remains the default until M2.

- **M0 — terminal spike**: raw mode + escape decoding + alt-screen +
  restore, inside the release, on macOS Terminal/iTerm/tmux. Throwaway.
- **M1 — substrate**: `event`/`screen`/`app` TEA skeleton, status bar,
  resize handling, tty detection + line-mode fallback. Golden-frame tests.
- **M2 — Navigator**: directory browsing, tenant activation, session
  state. The browse-first entry point exists from here on.
- **M3 — Discovery**: source enumeration, sampling, Schema mode,
  Inspector, cache persistence to `~/.efsql/cache/`.
- **M4 — Query mode at parity**: editor, history, scrollable results,
  meta-commands, plan overlay, pre-filled drill-downs from Schema mode.
  With browsing and querying both in place, the TUI becomes the default
  on a tty (`--no-tui` opts out).
- **M5 — Autocomplete**: context engine + popup, wired to session caches.
- **M6 — polish**: value-rendering rules everywhere, persisted history,
  help overlay, OSC 52 copy, larger-sample re-runs.

## 8. Risks / open questions

- **Raw-mode portability**: prim_tty raw mode is young; tmux/screen and
  odd TERMs need the M0 spike's attention. Mitigation: the line-mode
  fallback is always one branch away.
- **Single-writer discipline**: any stray `IO.puts` (e.g. from Logger)
  corrupts the frame — route Logger to a file in TUI mode.
- **Huge tenants**: discovery must stay strictly bounded (key-selector
  hops + fixed sample sizes); never a full scan the user didn't ask for —
  same principle as the `select *` guard.
- **Decided — browse-first**: the Navigator/Schema browser is the primary
  surface; the Query editor is a drill-down (§3).
- **Decided — caches persist**: discovery results persist across sessions
  under `~/.efsql/cache/`, with sample age always visible and re-sampling
  manual (§3.3).
- **Decided — open_readonly deferred**: the `exists?`-guarded `Tenant.open`
  stands; no upstream work now (§6).
