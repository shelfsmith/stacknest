// SPDX-License-Identifier: MIT

/// English body text for the in-app help. Mirrors `HelpContent.ja` block for block
/// (same sections, same block kinds and order, same link URLs) so `HelpContentParityTests`
/// can check the two stay in sync (G55 U5).
extension HelpContent {
    static var en: [HelpSection] {
        [
            HelpSection(title: "Overview", blocks: [
                .para("StackNest is an Apple Silicon–native image library manager. It's compatible with the Apple Property List XML libraries the original Stackroom writes, and browses and manages large image and comic collections (zip / cbz / cbr / 7z, folders, single images, PDF)."),
            ]),
            HelpSection(title: "Getting Started with a Library", blocks: [
                .para("On first launch (right after a fresh install), the first-run wizard walks you through how to open books and set up your first library. After that, you can choose from the title screen:"),
                .bullet("Create New Library — creates an empty `.stacknest` at any location"),
                .bullet("Open Existing Library — choose an existing `.stacknest`"),
                .bullet("Import from Stackroom Library — saves Stackroom's `Stackroom Library.xml` as a new `.stacknest`"),
                .para("Startup behavior (title screen / last library / a specific library) is set under Settings (⌘,) ▸ On Launch. Each library opens in its own window, and you can have several open at once."),
            ]),
            HelpSection(title: "Browse, Search, and Select", blocks: [
                .keyRow(action: "⇧/⌘ View Toggle & Selection", keys: "Switch grid/list view, arrow keys to move, ⇧+arrow for range selection, ⌘↑↓ / Home / End / Page Up/Down, Enter to open"),
                .keyRow(action: "Search", keys: "Toolbar search field (SQLite FTS5 full-text search)"),
                .para("Narrow down by attribute columns (individual values such as Genre / Author / Keywords) in the Browser pane. Smart Shelves build a dynamic collection from a condition expression (N conditions × AND/OR × match type). Use chips in the Stamp pane to apply an attribute to multiple books at once."),
            ]),
            HelpSection(title: "File Operations and Metadata", blocks: [
                .para("Add book files or folders by dropping them from Finder onto the grid, or with the toolbar's \"+\" button. **If a manual shelf or Favorites is showing, the books are added to that shelf too** (this also applies to books already in the library)."),
                .keyRow(action: "Remove from Library", keys: "⌫"),
                .keyRow(action: "Move to Trash", keys: "⌘⌫"),
                .keyRow(action: "Rename (Token Format)", keys: "⇧⌘R"),
                .para("Rename tokens can also include `@series` / `@volume` / `@keywordC` (volume numbers are zero-padded to match within the series). The same operation is also available from `stacknest-cli rename-files` and from MCP (see \"Command Line / AI Access\" below)."),
                .keyRow(action: "Move Files", keys: "⌘D"),
                .keyRow(action: "Set Rating", keys: "⌘0–5"),
                .keyRow(action: "Toggle Unread / Read", keys: "⌘T"),
                .keyRow(action: "This Library's Settings", keys: "⇧⌘,"),
                .keyRow(action: "App Settings", keys: "⌘,"),
            ]),
            HelpSection(title: "Changing the Cover", blocks: [
                .para("Each book's cover can be changed from the Detail pane. Right-click the cover (context menu) for:"),
                .bullet("Edit Cover — pick any page inside the archive and crop the visible area (formats with a notion of pages only. **EPUB and PDF are included too**; not available for videos)"),
                .bullet("Choose Cover from Scene… — for mp4 / mov / m4v, pick the scene to use as the cover from a player with a seek bar. You can then crop that scene too, or press \"Done\" without cropping to use the whole scene as the cover. The chosen scene is remembered, so \"Regenerate Cover\" can rebuild **the same scene** later (local books only; not available remotely)"),
                .bullet("Set Cover from External Image… — choose any image file (or **drag and drop** an image onto the cover in the Detail pane) → crop and set"),
                .bullet("Revert to Automatic — removes the manual cover and returns to the automatic cover from the first page"),
                .bullet("Regenerate Cover — rebuilds the cover from the current file (**per book**). Use this when you've replaced a file's contents but the cover is still the old one. Not available for books whose cover is an external image (by design, it won't be overwritten). After relinking a missing file, the cover and page count update automatically."),
                .para("Changing the cover only affects **the thumbnail**; it never touches the archive itself or the original file. The same operations are available remotely (with an edit token); if the cover changes on the sharing side or another client, reloading the list or reconnecting picks up the change."),
                .para("To regenerate covers for the whole library at once, use \"Regenerate Covers\" in this library's settings (⇧⌘,) (shows progress)."),
            ]),
            HelpSection(title: "Built-in Viewer", blocks: [
                .para("Opening a book displays it in a dedicated window (or full screen). Key controls:"),
                .viewerKeyTable,
                .para("Two-page spread, page direction, resume reading, and end-of-volume behavior are all saved per book. The Built-in/External Viewer choice can be set **separately for images and EPUB** (Settings ▸ View ▸ Viewer). Videos and text files (txt / md / rtf) can't open in the built-in viewer, so they always open in the external viewer. EPUB color scheme can be set to \"Match System / Light / Dark\" under Settings ▸ Built-in Viewer ▸ \"EPUB Color Scheme\"."),
                .para("**Page turn effects** can be set to \"None / Fade / Slide\" under Settings ▸ Built-in Viewer ▸ \"Page Turn Effect\" (default is \"None\"). This applies to both the image viewer and the EPUB window. It applies to turning to an adjacent page and to the slideshow, but not to jumps or volume changes. It's skipped while a key is held down, and when \"Reduce Motion\" is enabled in System Settings."),
                .para("The **Magnifier** zooms in on the area around the cursor. While it's on, **scrolling changes the zoom level** (shown in a HUD), and both **shape (circle / square) and size (small / medium / large)** can be set under Settings ▸ Built-in Viewer, where you can also check the zoom level and reset it to the default. The magnified area is re-decoded on the spot, so it never looks pixelated even at high zoom."),
                .para("**\"Allow Multiple Viewer Windows\"** (Settings ▸ Built-in Viewer) is off by default: the same book never opens twice, and opening a different book **keeps everything in one viewer window** (opening a book that's already open just brings it to the front). Turn it on and **different books can open in separate windows** (either way, the same book always stays consolidated into one)."),
            ]),
            HelpSection(title: "Reading EPUB (Beta)", blocks: [
                .para("Importing an EPUB reads its cover and metadata (title, author, language, binding direction) straight from the file. Double-click to open. This is **Beta**: it's readable, but behavior isn't fully settled within the constraints listed below."),
                .para("Key controls in the EPUB window are **shared with the built-in viewer** (Settings ▸ Built-in Viewer ▸ Key Bindings). Page turn, Home/End (start/end of book), number keys to jump to a position, `d` to toggle spread, `+`/`-`/`=` for text zoom, `s` for auto-scroll, `[`/`]` for volume navigation, `f` for full screen, and `?` for help all work. Image-only features such as the Magnifier or page skipping don't apply to EPUB. \"Open in Full Screen (EPUB)\" is a separate setting from the image viewer's."),
                .bullet("**Text EPUB** — opens in a dedicated window with vertical writing, ruby, two-page spreads, and right-to-left binding. Key controls follow the table shared with the built-in viewer (Home / End jump to the first / last page of the book; text zoom via `+` / `-` / `=` is saved as a setting). Reading position is saved per book."),
                .bullet("**Whole-book progress** — shows \"N / M\" for the whole book plus a progress bar at the bottom of the window (appears right after opening, on page turns, or on mouse movement, and fades after a moment). Until the whole book's page count has finished being measured, it shows \"Measuring…\", and the bar is an estimate based on chapter position. Jumping by percentage with a number key while still measuring moves by chapter instead, and shows \"Moving by chapter while measuring.\" To show a per-chapter page number under each page, turn on \"Show EPUB Page Numbers\" under Settings ▸ Built-in Viewer."),
                .bullet("**Resume / Start Over** — opening a book you've partly read asks \"Resume reading?\" It doesn't ask if you haven't moved past the first page."),
                .bullet("**Volume navigation** — if the next (or previous) volume is a text EPUB, **it replaces the book in the same window**. If that volume was partly read, it asks \"Resume / Start Over\". If the next volume is an image book it switches to the image viewer, and if moving on from the image viewer lands on a text EPUB it switches to the EPUB window. Full screen after switching follows **the destination's own setting** (\"Open in Full Screen (Image)\" / \"Open in Full Screen (EPUB)\"). If the next volume can't be opened, the window stays open, shows \"Can't open the next volume,\" and you can keep reading the current book."),
                .bullet("**Window position and size** — the EPUB window remembers its position and size, and opens the same way next time."),
                .bullet("**EPUB where every page is an image (manga)** — opens in the image viewer instead of the EPUB reader (two-page spread, right-to-left binding, zoom, Magnifier, and volume navigation all work as usual)."),
                .bullet("**Binding direction** — the EPUB's own setting is applied to the book on import. A book with no such setting follows the global default, and a right-click override always takes priority."),
                .bullet("**Remote / Web / Offline** — also readable in the Web reader (browser, iPad / iPhone) and from a remote library (another Mac's StackNest); reading position is shared across Mac, Web, and remote. Downloaded EPUBs can be read offline too (an offline reading position doesn't sync with the server). In the Web reader, a page that's a single image (a cover or illustration) fills the screen edge-to-edge, and the book's detail view lets you choose \"Resume Reading / Start Over\" for a book you've partly read. Tap the center of the screen to show or hide the top and bottom bars."),
                .bullet("**Constraints (why it's Beta)** — illustrations in a book mixing text and images don't form a two-page spread. There's no full-text search, table of contents, or annotations. Some EPUBs look off, such as ones with CSS aimed at Kobo. EPUB in the Web reader can't be saved for offline use."),
                .para("EPUB parsing and Mac-side rendering use Washi; the Web reader uses foliate-js (see \"Open Source and Acknowledgments\" below)."),
            ]),
            HelpSection(title: "External Viewer", blocks: [
                .para("To use an external viewer, choose it under Settings ▸ View (⌘,). Images and EPUB can be set separately. Pick the app (cooViewer, Avian, Preview, etc.) from \"Choose…\" under \"External Viewer\" on the same tab. Once set, double-clicking a book in the grid opens it in the external viewer. You can also assign a different viewer per type: EPUB has its own \"E-Book\" row (if not set, it opens with the \"Default\" setting). Videos and text files can't open in the built-in viewer, so they always open in the external viewer. Offline (downloaded) books follow the same settings, and are handed to the external viewer under a filename based on the book's title."),
            ]),
            HelpSection(title: "Using Remotely (Sharing, Client, Offline)", blocks: [
                .para("The same StackNest can act as either a server (sharing) or a client. You can browse your library from another Mac, or from a browser on an iPhone / tablet."),
                .bullet("Share — turn sharing on with the antenna (broadcast indicator) in the library's toolbar. Under \"Sharing Tokens\" in the server settings, create a separate token per person with its own permission level (View / Edit / Admin) and library visibility, then hand the URL / QR code / token to whoever's connecting. A locked library still needs to be unlocked with its password on the connecting side."),
                .bullet("View on the Web — open the shared URL in a browser on the connecting side (list / grid view, full-text search, sorting, paging; the Web reader supports two-page spread / single-page turning, resume reading, and two-way sync of reading direction). Pages can be **turned by dragging** (tracks your finger and settles with momentum when you let go). Going back from the reader to the list **keeps your scroll position and filters**."),
                .bullet("Native Client — enter the URL and token under \"Connect to Server…\" on the title screen (or the File menu). Browse with the full sidebar / facets / filters / detail view and the built-in viewer, with reading progress synced to the server. **An edit-permission sharing token allows editing from the Detail pane** (single or bulk metadata edits, applying stamps / editing stamp definitions, cover editing — choosing a page inside the archive, cropping, or drag-and-drop / menu to set an external image as cover — and reading direction; a view-only token is read-only)."),
                .bullet("Offline — while connected, right-click a book → \"Download\" (or select several in \"Select\" mode → bulk download). From \"Offline (Downloaded)\" on the title screen / File menu, you can list and read (resume, volume navigation) even without a server connection. A format set to open in an external viewer still opens there. Remove what you no longer need in bulk via \"Select\" mode, or by right-clicking in the remote library's grid / list and choosing \"Remove from Offline\"."),
                .bullet("Add / Remove (depends on permission) — with an Admin token you can remove books remotely. Deleting several books at once **shows progress and can be canceled partway through** (canceling stops the remaining, unprocessed ones). Even a view-only token can change Rating and Unread state, as a shared rating / viewing state."),
                .bullet("Cache and Sync — remote pages / covers are cached to disk on the device, so things stay fast after reconnecting or restarting. The viewer's progress bar shows a band for the cached range. If the cover changes on the server side, reloading the list or reconnecting picks it up (no need to clear the cache by hand). Manage the cache's size limit / retention period / usage / clearing under Settings ▸ View ▸ Remote Cache."),
                .para("Security: don't expose the port directly to the internet; using a VPN such as Tailscale or staying within your LAN is recommended (the database and image files themselves aren't encrypted)."),
            ]),
            HelpSection(title: "Auto-Import with Watched Folders", blocks: [
                .para("Watches folders you choose and **automatically imports** archives / image folders placed there. Add folders under Settings ▸ Import (Watched Folders), and assign a naming preset per folder. The first run can be reviewed in a preview, and import results appear as a banner at the top of the library window (**it doesn't auto-dismiss if some files failed to import**; \"Details\" shows which files failed and why, and × dismisses it). Auto-Classify (book type), the thickness threshold, and whether to use the EPUB title can each be overridden per library (\"Follow the Default\" / a custom value)."),
                .para("**How subfolders are handled** can be chosen per folder:"),
                .bullet("Don't Import Subfolders — only targets files directly inside the folder"),
                .bullet("Import Each Subfolder as One Book — treats each immediate subfolder as a single book (it doesn't go deeper). Loose files directly in the folder are still imported individually"),
                .bullet("Import Inside Subfolders Individually — scans recursively and imports each file inside as its own book"),
                .para("Books aren't moved; they're added by reference to their current location (added only, never removed). On shared volumes such as a NAS, it can take up to 60 seconds to notice a change."),
            ]),
            HelpSection(title: "Syncing with Finder Tags", blocks: [
                .para("**Syncs macOS Finder tags** two-way with one metadata field of a library. Choosing a field under this library's settings ▸ Import ▸ **Finder Tag Sync** turns it on (the default is \"Don't Sync\" — nothing happens)."),
                .para("Tags added in Finder go into the chosen field, and values you edit in StackNest become Finder tags. **Removing a tag on either side removes it from the other, too** (it remembers the last synced value; a simple merge would bring back a tag you'd just removed)."),
                .para("Sync runs **when the library is opened**, and **when you re-sync manually**. Re-sync from the circular-arrow button in the library window's toolbar (only shown for a library with sync enabled), or from \"Re-sync Now\" in the library's settings."),
                .bullet("**Fields that can sync** — six of them: Genre, Author, Subject, and Keywords A/B/C. **Series can't sync** (it's a single-value field, so a name containing the separator character would split into two tags in Finder)."),
                .bullet("**Tag colors are preserved** — StackNest has no concept of tag color itself, but it never removes a color that's already there."),
                .bullet("**A tag whose name contains \", \"** conflicts with the field's separator, so it isn't synced; a banner reports this."),
                .bullet("**On a volume with Spotlight indexing disabled**, the Finder → StackNest direction doesn't work (check with `mdutil -s <volume>`). A banner reports this case too; StackNest → Finder still works."),
                .para("**Doesn't depend on library size.** Only tagged items are looked up via Spotlight, so even a 12,000-book library finishes in about 0.4 seconds."),
            ]),
            HelpSection(title: "Command Line / AI Access (Local Access)", blocks: [
                .para("You can operate the library from the command line or an AI agent, without going through the GUI. Enable this under Settings ▸ General ▸ Local Access (limited to 127.0.0.1)."),
                .bullet("CLI — the bundled `stacknest-cli` handles listing / adding / removing / editing metadata / shelf CRUD / watching / locking / importing / relinking / duplicates / sharing tokens / stamps / labels (`stacknest-cli --help`). Passwords are read from stdin. Re-sync Finder tags with `stacknest-cli finder-tags resync`."),
                .bullet("MCP — registering `mcp-stacknest` (a Model Context Protocol server) lets a compatible AI agent perform the same operations."),
                .bullet("API Documentation — the local endpoint is API-only; opening the root (/) in a browser shows a Redoc (OpenAPI 3.1) API reference."),
            ]),
            HelpSection(title: "Integrity Check", blocks: [
                .para("Checks whether your books' archives are corrupted. File menu ▸ **Integrity Check…** opens a dedicated window (scanning doesn't block other operations or quitting the app)."),
                .bullet("**Scan Unchecked** — checks only books that haven't been checked yet."),
                .bullet("**Recheck All** — rechecks everything. Depending on library size, this **can take hours or even tens of hours**, so it confirms before starting."),
                .bullet("**Recheck Damaged Only** — rechecks only books that were flagged as damaged last time (useful after replacing a file, for example)."),
                .para("Checking has two levels. **Quick Check** looks at whether the file exists, its size, and whether it opens. **Detailed (CRC) Check** actually reads and verifies every entry inside the archive, so it's more reliable but slower. **You can pause at any time, and results so far are kept.**"),
                .para("**Books that were fine last time but are damaged now (degraded) appear at the top of the list.** This makes it easier to spot books that need restoring from a backup."),
                .para("Covers .zip / .cbz / .rar / .cbr / .7z and single images. Folders, videos, and PDF / EPUB have no CRC, so they're recorded as \"Not Applicable\" (this doesn't mean they aren't corrupted)."),
                .para("**Also works over a remote connection.** Since it's a long-running job, though, **starting it requires an Admin token** (the menu is only enabled once unlocked and with Admin permission). Remotely, since it points at files on the server machine, \"Reveal in Finder\" isn't available."),
                .para("The same operations are available from the command line with `stacknest-cli integrity scan / status / list / full-scan / job-status / cancel`."),
            ]),
            HelpSection(title: "Locking a Library", blocks: [
                .para("Each library can have a password lock (SHA-256 + salt, with Touch ID / Apple Watch unlock support). This is a lightweight lock meant to prevent accidental access; it doesn't encrypt the database or the image files themselves. Use something like FileVault alongside it if you need strong confidentiality."),
                .para("A locked library **needs to be unlocked again whenever you close the window and reopen it** (resuming via \"Resume Reading\" at launch also asks for it). The same applies over a remote connection. There's a limit on unlock password attempts, and repeated failures lock you out temporarily."),
                .para("**If a lock already exists, changing or removing the password requires the current password.** Even if you leave the library unlocked and step away, no one else can hijack it by changing the password (this requirement doesn't apply when setting a lock for the first time)."),
                .para("There's no recovery if you forget the password. You can remove the lock by deleting the lock-related rows from `library_settings` in `.stacknest/library.sqlite` (see the README for details)."),
            ]),
            HelpSection(title: "Links", blocks: [
                .link(label: "Source Code / README (GitHub)", url: HelpContent.repoURL),
                .link(label: "Original Stackroom (aroma / aromatics soft)", url: "https://aromaticsapp.blogspot.com/p/stackroom.html"),
                .para("StackNest is an independent, compatible implementation, unaffiliated with aroma / aromatics soft."),
            ]),
            HelpSection(title: "Open Source and Acknowledgments", blocks: [
                .para("StackNest uses the following open-source software (see each project's repository, or the bundled LICENSE, for the full license text)."),
                .link(label: "Washi — EPUB parsing and Mac-side rendering (vertical writing, ruby, two-page spreads). MIT / shunnag", url: "https://github.com/shunnag/Washi"),
                .link(label: "foliate-js — EPUB rendering in the Web reader. MIT / John Factotum", url: "https://github.com/johnfactotum/foliate-js"),
                .link(label: "zip.js — unpacks EPUB in the Web reader. BSD-3-Clause / Gildas Lormeau", url: "https://github.com/gildas-lormeau/zip.js"),
                .link(label: "GRDB.swift — SQLite. MIT / Gwendal Roué", url: "https://github.com/groue/GRDB.swift"),
                .link(label: "Hummingbird — the built-in server. Apache-2.0", url: "https://github.com/hummingbird-project/hummingbird"),
                .link(label: "swift-argument-parser — the command line. Apache-2.0 / Apple", url: "https://github.com/apple/swift-argument-parser"),
                .link(label: "libarchive — reading ZIP / RAR / 7z. BSD-2-Clause", url: "https://www.libarchive.org"),
            ]),
        ]
    }
}
