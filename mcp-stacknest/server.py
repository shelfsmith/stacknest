# SPDX-License-Identifier: MIT
"""StackNest MCP server. Wraps the stacknest CLI and exposes it as MCP tools.
The CLI auto-detects the connection from the same Mac's UserDefaults (assumes StackNest
is running with Local Access turned ON)."""
from __future__ import annotations

import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cli  # noqa: E402

from mcp.server.mcpserver import MCPServer  # noqa: E402

mcp = MCPServer("stacknest")


@mcp.tool()
def stacknest_libraries() -> Any:
    """Return the list of open StackNest libraries (id/name/bookCount/locked)."""
    return cli.libraries()


@mcp.tool()
def stacknest_list(library: str, query: str | None = None, limit: int | None = None,
                   sort: str | None = None, order: str | None = None,
                   scope: str | None = None, scope_id: int | None = None,
                   recent_days: int | None = None, fields: str | None = None,
                   filter_json: dict | None = None, browse_json: list | None = None,
                   library_token: str | None = None) -> Any:
    """Return a page of books in the library (items: each book's id and metadata; total: overall count).
    library is a library name or UUID (see stacknest_libraries). query searches; limit caps the count (max 500).
    sort/order/scope/filter_json/browse_json/fields filter and sort the results.
    library_token is a locked library's unlock token (from stacknest_unlock; the session cache is used automatically when omitted)."""
    return cli.list_books(library, query=query, limit=limit, sort=sort, order=order,
                          scope=scope, scope_id=scope_id, recent_days=recent_days,
                          fields=fields, filter_json=filter_json, browse_json=browse_json,
                          library_token=library_token)


@mcp.tool()
def stacknest_add(library: str, paths: list[str], preset: str | None = None,
                  library_token: str | None = None) -> Any:
    """Add server-local file/folder paths to the library as books (in place; files are not moved).
    addedIDs in the result are the ids of the books added; alreadyPresent lists ones already in the library; failed lists paths that failed.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.add(library, paths, preset=preset, library_token=library_token)


@mcp.tool()
def stacknest_set(library: str, id: int, title: str | None = None, author: str | None = None,
                  series: str | None = None, volume: int | None = None, genre: str | None = None,
                  keyword_a: str | None = None, keyword_b: str | None = None,
                  memo: str | None = None, neta: str | None = None, rating: int | None = None,
                  unseen: bool | None = None, book_type: int | None = None,
                  direction: str | None = None, library_token: str | None = None) -> str:
    """Update a book's metadata (only the fields given). Get id from stacknest_list.
    unseen: unread flag (true/false). book_type: book type (integer). direction: reading direction (ltr/rtl).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.set_meta(library, id, title=title, author=author, series=series, volume=volume,
                 genre=genre, keyword_a=keyword_a, keyword_b=keyword_b,
                 memo=memo, neta=neta, rating=rating,
                 unseen=unseen, book_type=book_type, direction=direction,
                 library_token=library_token)
    return f"updated book {id}"


@mcp.tool()
def stacknest_remove(library: str, ids: list[int], trash: bool = False,
                     library_token: str | None = None) -> str:
    """Remove books from the library (destructive). By default only removes the DB entries and keeps the files.
    trash=True also moves the files to the macOS Trash (recoverable). Get id from stacknest_list.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.remove(library, ids, trash=trash, library_token=library_token)
    return f"removed {len(ids)} book(s)"


@mcp.tool()
def stacknest_detail(library: str, id: int, library_token: str | None = None) -> Any:
    """Return all metadata for one book. Get id from stacknest_list.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.detail(library, id, library_token=library_token)


@mcp.tool()
def stacknest_facets(library: str, field: str, library_token: str | None = None) -> Any:
    """Return the distinct values for the given field (e.g. author/genre).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.facets(library, field, library_token=library_token)


@mcp.tool()
def stacknest_shelves(library: str, library_token: str | None = None) -> Any:
    """Return the library's shelves (smart and manual).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.shelves(library, library_token=library_token)


@mcp.tool()
def stacknest_me() -> Any:
    """Return the connection token's permissions (role/tier/scope)."""
    return cli.me()


# --- Shelf CRUD ---

@mcp.tool()
def stacknest_shelf_create(library: str, title: str,
                           smart: bool = False,
                           conditions: dict | None = None,
                           library_token: str | None = None) -> Any:
    """Create a shelf. smart=True makes a smart shelf (pass the condition JSON via conditions);
    False makes a manual shelf. The result includes the new shelf's id.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.shelf_create(library, title, smart=smart, conditions=conditions,
                            library_token=library_token)


@mcp.tool()
def stacknest_shelf_delete(library: str, shelf_id: int, library_token: str | None = None) -> str:
    """Delete a shelf (the books it contains stay in the library). Get shelf_id from stacknest_shelves.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.shelf_delete(library, shelf_id, library_token=library_token)
    return f"deleted shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_rename(library: str, shelf_id: int, title: str,
                           library_token: str | None = None) -> str:
    """Rename a shelf. library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.shelf_rename(library, shelf_id, title, library_token=library_token)
    return f"renamed shelf {shelf_id} to {title!r}"


@mcp.tool()
def stacknest_shelf_conditions_get(library: str, shelf_id: int,
                                   library_token: str | None = None) -> Any:
    """Get a smart shelf's condition JSON.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.shelf_conditions_get(library, shelf_id, library_token=library_token)


@mcp.tool()
def stacknest_shelf_conditions_set(library: str, shelf_id: int, conditions: dict,
                                   library_token: str | None = None) -> str:
    """Update a smart shelf's condition JSON. conditions has the shape {"version":1,"match":"all","rules":[...]}.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.shelf_conditions_set(library, shelf_id, conditions, library_token=library_token)
    return f"updated conditions for shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_add_books(library: str, shelf_id: int, ids: list[int],
                              library_token: str | None = None) -> str:
    """Add books to a manual shelf. ids is a list of book ids (see stacknest_list).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.shelf_add_books(library, shelf_id, ids, library_token=library_token)
    return f"added {len(ids)} book(s) to shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_remove_books(library: str, shelf_id: int, ids: list[int],
                                 library_token: str | None = None) -> str:
    """Remove books from a manual shelf (the books themselves stay in the library).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.shelf_remove_books(library, shelf_id, ids, library_token=library_token)
    return f"removed {len(ids)} book(s) from shelf {shelf_id}"


# --- Watched folders ---

@mcp.tool()
def stacknest_watch_get(library: str, library_token: str | None = None) -> Any:
    """Get the library's watched-folder settings.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.watch_get(library, library_token=library_token)


@mcp.tool()
def stacknest_watch_set(library: str, config: dict, library_token: str | None = None) -> str:
    """Replace the library's watched-folder settings.
    config has the WatchConfigDTO shape: {"enabled": true, "folders": [...]}.
    folders: [{"id": "...", "path": "/abs/path", "enabled": true,
               "presetID": null, "baseline": [],
               "subfolderMode": "topLevelOnly" | "archive" | "recurse"}]
      subfolderMode: topLevelOnly = don't import subfolders (top-level files only) /
                     archive = import each top-level subfolder as one book (does not descend further),
                     plus import top-level loose files individually /
                     recurse = recurse into subfolders and import their files individually.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.watch_set(library, config, library_token=library_token)
    return "watch config updated"


# --- Lock ---

@mcp.tool()
def stacknest_lock_set(library: str, password: str, current_password: str | None = None,
                       library_token: str | None = None) -> str:
    """Set or change a library's password lock.
    If the library already has a lock, current_password is required — a wrong or missing value is
    rejected and the lock is left unchanged. current_password is not needed when setting a new lock.
    The password is passed via the CLI's stdin and never appears in argv (secure).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.lock_set(library, password, current_password=current_password, library_token=library_token)
    return f"lock set for library {library!r}"


@mcp.tool()
def stacknest_lock_clear(library: str, current_password: str | None = None,
                         library_token: str | None = None) -> str:
    """Remove a library's password lock.
    If the library has a lock, current_password is required — a wrong or missing value is rejected.
    The password is passed via the CLI's stdin and never appears in argv (secure).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.lock_clear(library, current_password=current_password, library_token=library_token)
    return f"lock cleared for library {library!r}"


# --- Finder tag sync ---

@mcp.tool()
def stacknest_finder_tags_status(library: str, library_token: str | None = None) -> Any:
    """Return the Finder tag sync status (field = the synced column name or None, running = is it running,
    locked = is it locked). Only works on a library open in the app (errors if it isn't open).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.finder_tags_status(library, library_token=library_token)


@mcp.tool()
def stacknest_finder_tags_set(library: str, field: str | None = None,
                              library_token: str | None = None) -> Any:
    """Change which field syncs with Finder tags.
    field is one of genre / series / author / neta / keyword_a / keyword_b / keyword_c,
    or None / "none" (disable syncing). An unknown column name is an error.
    Note: changing the field clears all previously synced values (a deliberate, irreversible safeguard).
    Note: this feature writes the library's metadata into files as Finder tags. Use it only on a library you can afford to have written to.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.finder_tags_set(library, field, library_token=library_token)


@mcp.tool()
def stacknest_finder_tags_resync(library: str, library_token: str | None = None) -> Any:
    """Re-sync Finder tags now and wait for it to finish before returning the result.
    Follows the exact same path as the app's "Re-sync Finder Tags" menu item (does not run while locked).
    The result's status is started / noField / locked / alreadyRunning / noLibrary.
    When status is anything other than started, every count is 0 (don't use the counts to distinguish
    "nothing changed" from "refused").
    updatedInLibrary = Finder -> library, updatedInFinder = library -> Finder,
    skippedTags = tags not synced because they contain the ", " separator,
    indexingDisabledVolumes = volumes with Spotlight indexing disabled (if non-empty, Finder -> library isn't working).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.finder_tags_resync(library, library_token=library_token)


@mcp.tool()
def stacknest_rename_files(library: str, ids: list[int],
                           preset: str | None = None,
                           format: str | None = None,
                           apply: bool = False,
                           library_token: str | None = None) -> Any:
    """Rebuild file names from metadata. **With apply=False (the default), no file is moved.**
    Call it first without apply, look at the returned rows, then call again with apply=True to run it.
    ids is an array of book IDs (see stacknest_list).
    preset is the library's naming preset ID; format is a pattern like "@series v@volume".
    **preset and format cannot both be given.** Omitting both uses the library's default preset.
    Available tokens: @title @author @genre @keywordA @keywordB @keywordC @relation @type @series @volume.
    @volume is zero-padded to max(2, digit count of the series' highest volume).
    rows[].status is ok / unchanged / conflictExisting / conflictInBatch / emptyName / tooLong / noPath / missingFile.
    missingIDs lists IDs not in the library (these don't appear in rows).
    404 if the library isn't open. A locked library returns 403 if the library token is missing or expired, same as other operations.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.rename_files(library, ids, preset=preset, fmt=format,
                            apply=apply, library_token=library_token)


# --- Import settings ---

@mcp.tool()
def stacknest_import_config_get(library: str, library_token: str | None = None) -> Any:
    """Get the library's import settings (auto-classify, thickness detection, preset, etc.).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.import_config_get(library, library_token=library_token)


@mcp.tool()
def stacknest_import_config_set(library: str,
                                auto_classify: bool | None = None,
                                thick: int | None = None,
                                prefer_epub_title: bool | None = None,
                                library_token: str | None = None) -> str:
    """Update the library's import setting overrides (only the fields given).
    auto_classify: auto-classify book types ON/OFF. thick: thickness-detection threshold (page count).
    prefer_epub_title: prefer an EPUB's own title when it has one (omit to defer to the global default; omitting clears the override).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.import_config_set(library, auto_classify=auto_classify, thick=thick,
                          prefer_epub_title=prefer_epub_title, library_token=library_token)
    return f"import config updated for library {library!r}"


@mcp.tool()
def stacknest_import_config_global_get() -> Any:
    """Get the global import settings (the default shared by every library)."""
    return cli.import_config_global_get()


@mcp.tool()
def stacknest_import_config_global_set(auto_classify: bool, thick: int, prefer_epub_title: bool) -> str:
    """Update the global import settings (all values required; the shared default across every library; admin only).
    prefer_epub_title: prefer an EPUB's own title when it has one."""
    cli.import_config_global_set(auto_classify, thick, prefer_epub_title)
    return "global import config updated"


# --- Relink ---

@mcp.tool()
def stacknest_relink(library: str, id: int, new_path: str,
                     library_token: str | None = None) -> str:
    """Update a book's file path to a new location (repairs the link after a file was moved).
    id is a book id from stacknest_list. new_path is the absolute path after the move.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    cli.relink(library, id, new_path, library_token=library_token)
    return f"relinked book {id} to {new_path!r}"


# --- Duplicate detection ---

@mcp.tool()
def stacknest_dedup_scan(library: str, library_token: str | None = None) -> Any:
    """Scan the library for duplicate candidates and return the results (exact/possible groups plus stats).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.dedup_scan(library, library_token=library_token)


# --- Integrity check (G27a) ---

@mcp.tool()
def stacknest_integrity_scan(library: str, library_token: str | None = None) -> Any:
    """Run the quick check: open books with no page count yet and classify them, then return the counts.
    The results are persisted to the database, so stacknest_integrity_status / _list can read them
    afterward as many times as needed without rescanning."""
    return cli.integrity_scan(library, library_token=library_token)


@mcp.tool()
def stacknest_integrity_status(library: str, library_token: str | None = None) -> Any:
    """Return integrity check totals (checked / unchecked / damaged / degraded).
    degraded means a book that was ok last time and is damaged this time — suspected decay on disk."""
    return cli.integrity_status(library, library_token=library_token)


@mcp.tool()
def stacknest_integrity_list(library: str, status: str = "damaged",
                             library_token: str | None = None) -> Any:
    """List books in the given state (ok / damaged / empty / missing / unsupported)."""
    return cli.integrity_list(library, status=status, library_token=library_token)


# --- Full CRC scan (background job, G27b) ---

@mcp.tool()
def stacknest_integrity_full_scan(library: str, mode: str = "unchecked",
                                  library_token: str | None = None) -> str:
    """Start a full CRC verification as a background job (the detailed version of stacknest_integrity_scan's
    quick check — verifies the CRC of every entry in each archive).
    Measured rate: about 4.5 sec/book — at scale this can take tens of hours (e.g. about 31 hours for 22,880 books).
    **This tool returns as soon as the job has started (or is already running); it does not wait for it to finish.**
    Check progress with stacknest_integrity_job_status, and cancel with stacknest_integrity_cancel if needed.
    mode: "unchecked" (default, unchecked only) / "all" (recheck everything; needed to detect bit rot) /
    "damaged" (recheck only books that were damaged last time; useful after a repair).
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.integrity_full_scan(library, mode=mode, library_token=library_token)


@mcp.tool()
def stacknest_integrity_job_status(library: str, library_token: str | None = None) -> Any:
    """Return the progress of the running maintenance job (full-scan, complete-metadata, compress-covers, etc.).
    Includes running/job/done/total/startedAt; only running=false is present when nothing is running.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.integrity_job_status(library, library_token=library_token)


@mcp.tool()
def stacknest_integrity_cancel(library: str, library_token: str | None = None) -> str:
    """Cancel the running maintenance job (including full-scan); a no-op if none is running.
    library_token is a locked library's unlock token (the session cache is used automatically when omitted)."""
    return cli.integrity_cancel(library, library_token=library_token)


# --- Unlock ---

@mcp.tool()
def stacknest_unlock(library: str, password: str) -> Any:
    """Unlock a locked library and return a short-lived library token ({"libraryToken": ...}).
    The password is passed via the CLI's stdin and never appears in argv.
    After unlocking, the token/password are cached for the session, so later tools can omit
    library_token and access this library automatically (an expired token is refreshed automatically)."""
    return cli.unlock(library, password)


# --- Grant CRUD (admin) ---

@mcp.tool()
def stacknest_grant_list() -> Any:
    """Return the list of access grants (id/label/tier/scope/token). Requires an admin connection."""
    return cli.grant_list()


@mcp.tool()
def stacknest_grant_create(label: str, tier: str, scope: dict | None = None) -> Any:
    """Create a grant and return the result, including its token. tier is read/edit/admin.
    scope is {"libraries":["uuid",...]} to limit it, or omit for every library. Requires admin."""
    return cli.grant_create(label, tier, scope=scope)


@mcp.tool()
def stacknest_grant_update(grant_id: str, label: str | None = None,
                           tier: str | None = None, scope: dict | None = None) -> Any:
    """Update a grant (only the fields given). Requires admin."""
    return cli.grant_update(grant_id, label=label, tier=tier, scope=scope)


@mcp.tool()
def stacknest_grant_delete(grant_id: str) -> str:
    """Delete a grant. Requires admin."""
    cli.grant_delete(grant_id)
    return f"deleted grant {grant_id}"


# --- Bulk stamp / label customization ---

@mcp.tool()
def stacknest_stamp_apply(library: str, field: str, book_ids: list[int],
                          value: str | None = None, clear: bool = False,
                          library_token: str | None = None) -> Any:
    """Bulk-stamp (append) a value across books, or clear it. Give either value or clear.
    field is the target column (genre/keyword_a etc.). Requires edit access."""
    return cli.stamp_apply(library, field, book_ids, value=value, clear=clear,
                           library_token=library_token)


@mcp.tool()
def stacknest_stamp_definitions_get(library: str, library_token: str | None = None) -> Any:
    """Get the stamp definitions (dbColumn -> candidate values)."""
    return cli.stamp_definitions_get(library, library_token=library_token)


@mcp.tool()
def stacknest_stamp_definitions_set(library: str, definitions: dict,
                                    library_token: str | None = None) -> Any:
    """Replace the stamp definitions entirely. definitions has the shape {"genre":["..."],...}. Requires edit access."""
    return cli.stamp_definitions_set(library, definitions, library_token=library_token)


@mcp.tool()
def stacknest_label_get(library: str, library_token: str | None = None) -> Any:
    """Get the label customization (customFieldLabels/customBookTypeLabels)."""
    return cli.label_get(library, library_token=library_token)


@mcp.tool()
def stacknest_label_set(library: str, settings: dict, library_token: str | None = None) -> Any:
    """Update the label customization. settings has the shape {"customFieldLabels":{...},"customBookTypeLabels":{...}}. Requires edit access."""
    return cli.label_set(library, settings, library_token=library_token)


# --- Open/close a library (local control only, G27b Task7) ---

@mcp.tool()
def stacknest_library_open(path: str) -> Any:
    """Open a library window at the given path (lets a library with no window be controlled headlessly).
    If that path is already open, no new window opens and the existing uuid is returned as-is.
    Works on a locked library too (opens it showing the unlock screen; stacknest_unlock is then needed for further operations).
    A path that doesn't exist or isn't supported is an error.
    **Local control only** — only works from the same Mac StackNest is running on, not via a shared server."""
    return cli.library_open(path)


@mcp.tool()
def stacknest_library_close(uuid: str) -> str:
    """Close a library window by uuid. Get uuid from stacknest_libraries or the return value of
    stacknest_library_open.
    **Local control only** — only works from the same Mac StackNest is running on, not via a shared server."""
    cli.library_close(uuid)
    return f"closed library {uuid}"


if __name__ == "__main__":
    mcp.run()
