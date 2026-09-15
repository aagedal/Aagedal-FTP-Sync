# Metadata Programming MCP

The same local stdio server exposes five tools to Codex, Claude Code, and OpenCode:
`fetch_jobs`, `fetch_photographers`, `add_photographer`,
`fetch_metadata_clips`, and `add_metadata_clip`.

The app must be running with admitted version 3 storage. It creates a private
`mcp-bridge` directory beside its v3 stores. The Python server translates MCP
calls into request files there; the running app executes the requests against
its current `AppStore` and writes replies. The server cannot edit stored JSON
directly. An open, unsaved metadata draft blocks additions for that job. Normal
app validation rejects duplicate photographer initials, missing references,
invalid dates or GPS, and overlapping clips. Saved edits trigger the app's
existing calendar change observation when calendar sync is active.

Project-scoped configuration is included in [Codex](../../.codex/config.toml),
[Claude Code](../../.mcp.json), and [OpenCode](../../opencode.jsonc). Start the
newly built app and restart each client after changing configuration. Claude
Code asks you to trust a project-scoped MCP server in interactive sessions.
Use each client's MCP status command to check connectivity: `codex mcp list`,
`claude mcp list`, or `opencode mcp list`.

`add_photographer` requires `job_id`, `name`, and `filename_initials`. It adds a
new profile to that job and to the shared photographer library. The camera
initials may be comma-separated. `add_metadata_clip` requires `job_id`,
`photographer_id`, `name`, `starts_at`, and `ends_at`; it accepts literal
`headline`, `description`, `keywords`, and optional `gps` coordinates.
Timestamps must include an ISO 8601 time zone. A clip creates the relevant
photographer day tracks, including when it crosses midnight.

`fetch_photographers` lists the shared library unless `job_id` is supplied.
`fetch_metadata_clips` requires `job_id`; optional `ends_after` and
`starts_before` select clips that overlap that interval. The fetch tools read
saved app state. `fetch_jobs` flags jobs with unsaved metadata drafts.

If the app uses a nonstandard sandbox or test location, set
`AAGEDAL_MCP_BRIDGE_DIR` to the absolute path of its `mcp-bridge` directory in
the MCP server environment. The adapter otherwise checks the macOS sandbox
container and ordinary Application Support locations.

The server uses only Python's standard library. Run its tests with:

```sh
python3 -m unittest discover -s Tools/MetadataMCP -p 'test_*.py' -v
```
