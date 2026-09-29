# Changelog

All notable changes to Kōwhai Audiobook Player are documented here.

## [2.1.0] - 2026-08-23

### Added
- **Correct multi-device resume** - Restoring positions from Google Drive now resumes at the exact chapter and offset instead of the start of the book. Legacy rows repair themselves on the next library scan.
- **Chapter-level position backup (JSON v2)** - Backups record per-chapter offsets going forward. Backups written by 2.1.0 import fine into future versions; restoring a 2.1.0 backup into an older build falls back to approximate progress.
- **Bookmark undo** - Deleting a bookmark offers a short Undo snackbar.
- **Persisted filters & view mode** - Progress-filter pills and grid/list choice are remembered across sessions.

### Fixed
- Download cancel/retry races hardened; cancelled jobs can no longer resurrect mid-queue.
- Drive folder/file names with filesystem-hostile characters are sanitised before use as local paths.
- M4B chapter ordering and FullBox metadata parsing fixes; OPF lookups no longer require namespaces.
- Startup recovery no longer blocks first frame; consent revocation now fully stops collection; cast URLs are redacted from logs.

### Changed
- **Performance on large libraries** - Metadata scanning runs in background-isolate chunks; covers decode at display-sized resolution; mini-player/sleep-timer rebuilds scoped.
- Live scan-phase labels; search debounced; download-progress events throttled at source.
- CI pins Flutter (3.44.4), adds a non-blocking Android build canary; MIT LICENSE added; internal naming unified under Kowhai.

### Under the hood
- Download progress unified behind a single tracker; library screen decomposed into focused modules; ~60 new tests (suite: 415 green).

---

## [Unreleased]

### Fixed
- **Fast-forward no longer rewinds the book** - When the total duration was not yet known, the skip-forward target was clamped against zero, so skipping forward from the lock screen could seek back to 0:00.
- **Filesystem-safe filename sanitising** - A Drive filename whose "extension" was longer than the length cap made the truncation arithmetic go negative and threw, turning the sanitiser itself into a crash. A crafted `.cue` sheet can no longer reference files outside its book folder, and `.cue` chapters are validated, sorted, and no longer mislabel chapter 1 with the disc title.
- **Malformed M4B resilience** - Box and sample-table sizes read from the file are now capped, so a small corrupt file can no longer force a multi-gigabyte allocation during a library scan.
- **Sleep timer "end of chapter" works for M4B** - It previously only triggered for multi-file books; on M4B (single file, chapter index always 0) the option armed and displayed but never stopped playback.
- **Bookmark swipe-delete** - Dismissing a bookmark no longer leaves it in the tree long enough to trip a framework assertion in debug builds.
- **Drive download integrity** - Files promoted out of staging are repointed in the database before the staging copy is removed (an interrupted move used to strand the book on a path that no longer existed, permanently), Drive imports are transactional, and a failed download no longer shows a stuck progress spinner.
- **Sleep/listen position correctness** - Opening the app, browsing, then pressing play no longer rewinds the book by the browsing time; a resume point is no longer computed past the end of a zero-length track; digit runs beyond 64 bits in filenames sort numerically.
- **Library filter sheet** - The active-filter highlight and "Clear all" now update as you pick, and an availability filter with no matches offers a way back instead of pointing at your folder layout.
- **Crash-free screens** - Removed `setState`-after-dispose and null-metadata crashes across settings, history, player, book details, and the Drive download surfaces.
- **Metadata sidecar reads capped** - An oversized `.cue` or `metadata.opf` in a scanned folder degrades to "no metadata" rather than exhausting memory mid-scan.
- Repaired garbled characters in several scan-status strings and the search hint.

### Security
- **Local file server** - The Cast streaming server now refuses peers that are not on your local network, shuts itself down when idle (a session that ended without an explicit stop used to keep serving), compares its access token without an early exit, and caps concurrent connections.
- **Release build is minified** - R8 and resource shrinking are enabled, so the shipped APK is no longer a readable copy of the app.
- **App data excluded from backup** - Reading history, bookmarks with your notes, and stored Drive folder references are no longer eligible for cloud backup or device transfer.

### Changed
- Foreign keys are now actually enforced, and the Drive book upsert was converted off `ConflictAlgorithm.replace` so enabling that pragma cannot cascade-delete downloaded-file rows.
- Audio metadata is only re-published to the media session when it actually changes, rather than several times a second.
- Google Drive metadata requests and library loads do fewer redundant database round-trips.

### Under the hood
- Static analysis pass across the codebase: ~45 defects fixed across parsing, data integrity, playback, and UI lifecycle, with regression tests added for each (suite: 462 green).

---

## [4.0.0] - 2026-08-24

### Added
- **Author-aware cover enrichment** - Missing covers are now searched with author + title for better matches, falling back to title-only (telemetry counts fallbacks).
- **Responsive library grid** - Columns scale to screen width via max-extent sizing; tablets and foldables no longer stuck at two columns.
- **Drive folder nesting** - Drive libraries now support the same layouts as local folders: flat, author/book, and author/series/book (depth 3).

### Fixed
- Enrichment service no longer replaces dependency-injected HTTP clients mid-run.


---

## [3.0.0] - 2026-08-24

### Changed (BREAKING - dependency modernization)
- **google_sign_in 6 -> 7** with the full auth/authorization split:
  silent restore uses `attemptLightweightAuthentication`, interactive sign-in
  uses `authenticate(scopeHint:)` so supported platforms combine the consent
  flows; write scope still requested only when sync is enabled via
  `authorizeScopes`; `hasWriteScope` now checks a silent authorization token
  (cross-platform replacement for web-only `canAccessScopes`).

> DEVICE VERIFICATION PENDING: OAuth grant/scope prompts must be exercised on
> a real device before relying on this build. If Drive sign-in misbehaves,
> file an issue - rollback is v2.1.0.


### Added
- **Persisted status filter** — the progress filter pills (Not started / In progress / Finished) are now remembered across sessions, matching the availability filter.
- **Bookmark undo** — deleting a bookmark offers a short Undo snackbar instead of dropping it immediately.

### Changed
- **Live scan status** — the library scan overlay steps through "Scanning your library…", "Checking Google Drive…" and "Loading covers…" instead of a single static label.
- **Snappier startup** — stale-download recovery and Drive position auto-restore now run after the first frame; download-size labels prefetch during scan instead of during list scrolling.
- The Drive download badge now follows the theme's primary colour.

### Changed (earlier in this cycle)
- **CI** — Flutter version pinned (3.44.4) with pub caching in both workflows, ending local/CI SDK drift; release APK builds now use the workflow run number as the Android build number so sideload updates always upgrade cleanly.
- **Repo hygiene** — Removed the stale `assets/lib` app copy and duplicate `.analysis_options.yaml`; unified leftover "AudioVault"/`sbcover` naming to Kōwhai (`KowhaiApp`, `[Kowhai:*]` log tags); added MIT `LICENSE` file.
- **Tests** — Retired the intentionally-failing exploration suite; its download-prompt gating coverage now lives in the preservation suite as Property 6. Mocks regenerated against current interfaces and the global analyzer suppression removed.
- **Fonts** — Manrope and Playfair Display are now bundled with the app instead of fetched from Google's font CDN at runtime. First launch is fully offline-safe, renders correctly with no network, makes no unconsented Google network call, and no longer flashes fallback fonts. The `google_fonts` dependency was removed.
- **Performance** — The mini player's frosted-glass blur surface no longer repaints on every position tick (only the thin progress bar and "x left" label do), and a running sleep timer no longer rebuilds the whole player screen every second — only its chip.
- **Library** — Grid/list layout choice is remembered between launches, search input is debounced for smoother typing on large libraries, and the metadata-enrichment checkbox on first-run now matches the Settings default.

### Fixed
- **Finished status lost on playback** — Books manually marked Finished stayed finished; periodic position saves no longer reset the status you set.
- **Cross-device restore fidelity** — Synced positions now restore to the exact chapter and offset instead of the start of the book; legacy backups without chapter data are repaired automatically the first time the book is opened.
- **Cast switching** — Loading a different book while casting now resumes it from its own saved position (previously it could start at the previous book's playback point), and a dying receiver can no longer overwrite good progress with 0:00.
- **Cast teardown** — Stopping playback during Cast now reliably ends the streaming server and saves the last known receiver position.
- **Privacy** — Revoking analytics consent in Settings now also uninstalls the crash-reporting handlers, and no telemetry events can fire before consent is granted. Cast streaming no longer logs the session token, and its server binds to the LAN interface instead of all interfaces (also fixing a rare stuck-streaming-server after rapid reconnects).
- **Changelog accuracy** — Corrected two historical release dates against git tag history ([1.5.0] and [1.2.0]).
- **Test environment** — A stale shader build cache caused a false-positive failure in the download-prompt preservation suite; resolved by `flutter clean` and guarded against recurrence by pinning CI's Flutter version.
- **Download cancellation** — Cancelling a download during its between-retries window no longer resurrects the cancelled file, and cancelling an idle queue no longer silently disables retries for that book's next attempt.
- **Startup recovery** — A single unreadable leftover download file no longer blocks app launch, and files whose expected size was never recorded are no longer deleted during crash recovery.
- **Drive folder names** — Folder and file names coming from Google Drive are sanitised before being used as filesystem paths, so names containing `/`, `\`, or traversal segments can no longer escape the library folder (they also no longer break scanning or downloads).
- **Scan errors** — An unreadable library root is now logged and rethrown so the UI can show its retryable error message consistently.
- **M4B chapters** — Chapters stored under the standard `meta` FullBox header (common in iTunes-style files) are now found; out-of-order chapter tables are sorted chronologically, and chapter lookup is now a binary search.
- **OPF metadata** — `metadata.opf` files that declare Dublin Core as the default namespace (no `dc:` prefixes) now parse instead of silently yielding empty metadata.

---

## [2.0.0] — 2026-04-28

### Added

- **Material 3 visual refresh** — New amber/brown colour palette with Manrope + Playfair Display fonts, updated splash screen and app icon across all platforms.
- **Download progress sheet** — Tapping a book that's actively downloading now shows a dedicated progress sheet with a live progress bar, byte counts, and a "Cancel download" option. Previously it re-showed the start-download prompt.
- **Cancel download from library list** — The three-dot menu on list-view tiles now shows "Cancel download" (in red) when a book is actively downloading, replacing the "Download" item.
- **Drive rescan progress text** — The "Rescan Drive" row in Settings now shows live status text ("Scanning Drive folder…", "Processing 3 of 12 books…") instead of just a spinner.
- **Library scan retry button** — The library error state now shows an error icon and a "Retry" button instead of just red text.
- **Settings batch load** — All settings are now loaded in a single batch via `SettingsSnapshot`, reducing async gaps and improving Settings screen load time.

### Changed

- **Grid cards** — Pure square covers with no text block; title rendered on the colour placeholder for books without artwork. List-tile thumbnails show a single large initial letter.
- **Mini player** — Frosted-glass backdrop with a filled primary-colour play/pause circle, matching the player screen.
- **Player screen** — Streamlined vertical spacing; chapter bar handles overflow gracefully; book-remaining time shown inline below the scrubber.
- **Placeholder colours** — Stable path-based hashing ensures each book gets a consistent colour across grid, list, and player views regardless of sort order.
- **Button style consistency** — Standardised across all screens: `FilledButton` for primary actions, `OutlinedButton` for secondary, `TextButton` for tertiary/cancel. Settings Drive "Connect" upgraded from tonal to filled; "Disconnect" from text to outlined.
- **Download confirmation consistency** — The "Download to device" button in book details now shows the same download sheet (with size and mobile data warning) as tapping from the library, instead of starting the download immediately.

### Fixed

- **Multi-file book progress stuck at 0:00** — The player screen progress section was treating `just_audio`'s per-file position as a global position for multi-file books. After jumping to chapter 10, elapsed time showed 0:00 and remaining showed the full book duration. Position is now correctly converted to global coordinates, and slider seeking maps back to the correct file + offset.
- **History screen empty for Drive books** — The history screen only received local books (`_rawBooks`), so Drive books with saved positions never appeared. It now receives the combined local + Drive book list.

### Internal

- `PreferencesService.getSettingsSnapshot()` loads all preferences in one `SharedPreferences` read.
- `DriveLibraryService.rescanDrive()` accepts an optional `onProgress` callback.
- `AudiobookListTile` gains `isDownloading` and `onCancelDownloadPressed` props.
- `_LibraryScreenState` tracks downloading folder IDs for list-view menu state.

---

## [1.6.6] — 2026-04-26

### Fixed

- **Bookmark while casting records correct position** — Adding a bookmark during a Cast session now captures the receiver's playback position instead of the local player's stale position.
- **Drive sync toggle no longer prompts for OAuth twice** — Enabling Drive sync when write access was already granted previously triggered a second interactive consent dialog. The scope check is now non-interactive.
- **Drive queries handle apostrophes and backslashes in names** — Folder or file names containing `'` or `\` (e.g. "It's a Wonderful Life") previously generated a malformed Drive API query and silently failed. Names are now correctly escaped.
- **Marking a book's status no longer resets chapter position** — Calling `setBookStatus` on a book with saved progress overwrote the chapter index and position to zero. The update now only touches the status column, leaving progress intact.
- **Cover art fetches for books found mid-scan** — If a second library scan completed while cover enrichment was already running, the newly found books were silently dropped and never enriched until the next app launch. They are now queued and processed after the current batch finishes.

### Internal

- Removed dead `CacheManager` service (was never wired into the app).
- Centralised duration formatting into a shared `fmtHourMin` helper; removed four ad-hoc copies across cards, tiles, and screens.
- Consolidated chapter-offset arithmetic into `calculateGlobalPosition`; removed five hand-rolled loops across `MiniPlayer`, `PlayerScreen`, and `BookDetailsScreen`.
- Extracted `EnrichmentAwareCover` into a shared widget (`lib/widgets/enrichment_aware_cover.dart`); `AudiobookCard` and `AudiobookListTile` now use the single canonical implementation.
- `MiniPlayer` now subscribes once to `effectivePositionStream` instead of twice, halving the ~5 Hz rebuild work.

---

## [1.6.5] — 2026-04-26

### Fixed

- **Drive books no longer create folders in the library before download** — Discovered (but undownloaded) Drive books were immediately creating a folder inside the local Audiobooks directory containing only `cover.jpg`. Downloaded files are now staged in app storage and only moved to the library folder when the download is complete (`promoteToLocal`).
- **Partial Drive files incorrectly marked as downloaded after process kill** — If Android killed the app mid-download, the incomplete file on disk caused `resetStaleDownloads` to mark it as fully downloaded on restart. It now compares actual file size against the expected size: exact match → done, otherwise the partial file is deleted and the record is reset so the download can start cleanly.
- **Drive downloads not resuming after app returns to foreground** — On iOS (app suspension) and Android Doze, the 30-second chunk timeout would mark in-flight downloads as errored. The app now automatically re-enqueues any errored, not-yet-complete downloads when it returns to the foreground.

---

## [1.6.4] — 2026-04-26

### Fixed

- **Library card shows stale download state after "Remove from device"** — After removing a downloaded Drive book from the device, the library grid card continued to show the "downloaded" cloud badge instead of the download icon. Tapping the card or manually refreshing would show the correct state. The `DriveDownloadOverlay` now re-reads download state from the database when the book's audio file count changes, so the correct undownloaded state is shown immediately.
- **Defensive fallback when re-fetching book before playback** — If `promoteToLocal` fails (e.g. scanner cannot read the download directory), the details screen now falls back to loading the book from the database directly, ensuring audio file paths are always available before handing off to the player.

---

## [1.6.3] — 2026-04-26

### Fixed

- **Drive book stuck in "undownloaded" state after download completes** — After a download finished, the book details screen would re-show the download prompt when tapping "Start listening" instead of opening the player. The details screen was reading file presence from the stale `Audiobook` object passed at navigation time rather than the live event-driven counts. It now uses download event counts (sourced from the DB via `DriveBookRepository`) to determine whether a book is fully downloaded, so the state always reflects reality.
- **Stale audioFiles when navigating to player post-download** — When "Start listening" is tapped after a download completes on the details screen, the fresh book (with actual audio file paths) is now fetched from `DriveLibraryService` before opening the player, preventing the player from opening with an empty playlist.
- **Silent failure swallowed in library refresh** — Errors thrown by `_refreshDriveBook` after a download event were silently dropped (unawaited fire-and-forget). Errors are now caught and logged, and `_applySort` is properly awaited so the library grid reliably updates when a download finishes.

---

## [1.6.2] — 2026-04-25

### Fixed

- **Download prompt shows file size on WiFi** — The "Download" bottom sheet now always fetches and displays the book's file size regardless of connection type. Previously the size was only shown on mobile data; on WiFi the prompt showed a generic message with no size and an unlabelled "Download" button.
- **"Start listening" on undownloaded Drive book** — Tapping "Start listening" on the book details screen for a Drive book that hasn't been downloaded no longer opens the player with no audio. It now shows the same download prompt as the library screen, including the file size.

### Internal

- Extracted `showDriveDownloadSheet` from `LibraryScreen` into `lib/utils/drive_download_sheet.dart` so both the library and book details screens share the same prompt logic.
- Moved `formatBytes` from `library_screen.dart` to `lib/utils/formatters.dart`.

---

## [1.6.1] — 2026-04-22

### Fixed

- **Drive onboarding scan** — Selecting a Google Drive folder during onboarding now immediately triggers a scan; new users no longer see an empty library that requires a manual rescan.
- **Download icon visibility** — Drive book download icon now sits inside a semi-transparent dark circle, making it visible on light-coloured covers.
- **Sleep timer sheet** — Now scrollable on small screens; all options including Custom… are reachable without the sheet expanding to full height.
- **Speed sheet** — Removed Cancel/Done buttons; dismissing keeps the last-set speed, consistent with other player sheets. Title left-aligned.
- **Library filter/sort sheets** — Aligned to player sheet style (manual drag handle, `titleMedium`, `SafeArea`). Sort sheet Cancel button removed — dismiss by backdrop tap or drag.
- **Player "remaining overall" label** — Shortened to "left".

### Changed

- **Placeholder tile colours** — Switched from dark jewel tones to lighter muted mid-tones, less overpowering on the light theme.

---

## [1.6.0] — 2026-04-22

### Changed

- **Player screen streamlined** — App bar title removed; bookmarks moved to an app bar icon alongside book details and Cast. The player body is less cluttered and the title/author/chapter info section carries more visual weight.
- **Speed sheet** — Replaced Cancel/Done buttons with immediate live-apply on dismiss, consistent with the sleep timer and bookmarks sheets. Title is now left-aligned.
- **Sleep timer sheet** — Now scrollable via a constrained `ListView`, so all options (including Custom…) are reachable on small screens without the sheet expanding to full height.

### Internal

- Extracted `SpeedDialog`, `ChapterListSheet`, `CastPickerDialog`, `LibraryOverflowMenu`, and `MiniPlayer` widgets from their parent screens.
- Extracted `M4bChapterParser` into a dedicated service with full test coverage.
- Added 30 s HTTP timeout to all Drive API calls.
- Fixed download manager fallback path to use `getApplicationDocumentsDirectory()` instead of `/tmp`.

---

## [1.5.0] - 2026-04-20

### Added

- **Progress sync** — Positions are automatically backed up to `positions.json` in the audiobooks root folder (within 30 s of any change, immediately on app background). An optional "Sync progress to Drive" toggle in Settings uploads the backup to an `AudioVault/` subfolder in a chosen Drive location; on first launch with an empty database and sync enabled, positions are silently restored from Drive. Drive write access is requested only when the toggle is turned on.
- **metadata.opf support** — When scanning a book folder, AudioVault reads a `metadata.opf` file (Calibre/OverDrive format) if present. OPF values take precedence over embedded audio tags for title, author, narrator, description, publisher, language, release date, and series. Series is displayed as e.g. "The Stormlight Archive #1" in book details. Narrator is shown in the player below the author.
- **Chapter bookmarks** — Bookmark any moment while listening. Tap the Bookmarks chip in the player bottom row to view or add bookmarks for the current book. Name and Notes fields are optional; an unnamed bookmark defaults to `Chapter X — H:MM:SS`. Bookmarks appear in the book details screen; tapping one jumps to the player at that position. Swipe-to-delete in both locations.

### Security

- **Cast server session token** — The local HTTP server now generates a random 16-byte hex token per Cast session. All served URLs embed the token; requests without it return 404, preventing other LAN devices from accessing audio files while casting.

### Accessibility

- Semantic labels on player transport controls, play/pause, chapter label, and speed chip; tooltips on all icon buttons; decorative badges (now playing, finished, DRM) labelled for screen readers; settings dialog rows meet the 48dp touch target minimum; large-text (2×) widget tests added.

### Internal

- Enrichment cancellation now aborts in-flight HTTP requests immediately via `http.Client.close()`.
- `ScannerService.maxScanDepth` constant documented and boundary-tested.
- `PositionService._deriveStatus` extracted as a shared helper.

---

## [1.4.0] — 2026-04-19

### Changed

- **Library header redesign** — The AppBar is pared back to Sleep Timer, Search, and a ⋯ overflow menu (Listen history, Rescan library, Settings). The title "My Library" is always fully visible.
- **Inline search bar** — Tapping Search expands an animated search bar below the header instead of replacing the title.
- **View bar** — A new pinned row below the header shows the filtered book count and active filter/sort summary, with grid/list toggle on the left and Filter + Sort buttons on the right.
- **Filter and Sort bottom sheets** — Progress filtering moves into a Filter sheet with an explicit "All" pill as the default. Sort moves into its own sheet — a simple list with a check against the active option and a Cancel action. Both sheets auto-apply on tap.
- **Coloured placeholder tiles** — Books without cover art now render as deterministic jewel-tone tiles allocated sequentially across the grid/list so adjacent placeholders never share a colour. The default book icon has been removed for a cleaner look.
- **Frosted-glass mini player** — The mini player uses a backdrop blur so it reads as a floating layer above the library content.
- **Drive tiles** — Removed the dark scrim over undownloaded Drive books; the download icon sits directly on the cover/placeholder for a lighter visual weight.

### Removed

- The old filter chip row above the library grid (replaced by the Filter sheet).
- The standalone sort icon, view-toggle icon, rescan icon, history icon, and settings icon in the AppBar (consolidated into the ⋯ menu and view bar).

---

## [1.3.0] — 2026-04-19

### Added

- **Library sort menu** — New sort picker in the library AppBar with Last played, Title (A–Z), Author (A–Z), Date added, and Duration (longest first). Selection persists across launches.
- **Sleep timer indicator outside the player** — A small countdown chip appears in the library AppBar when a sleep timer is running, so you can see remaining time without opening the player. Tap it to jump back into the current book.
- **Visual feedback during cover enrichment** — Books being enriched in the background show a subtle loading indicator on their cover until the new artwork arrives.
- **Playback error recovery** — Playback errors now surface a toast with a retry action instead of silently failing.
- **Startup loading labels** — The initial library scan screen now labels what it's doing (scanning folder, syncing Drive, etc.) so long waits aren't opaque.

### Changed

- **Combined search + filter empty state** — When a search query and a status filter both return nothing, the empty state names both constraints and offers a single "Clear filters" action.
- **Drive sign-in logs** — User email is no longer included in debug logs; sign-in and session-restore events log a generic status string instead.
- **Cast init errors** — Google Cast initialisation failures are now logged instead of being silently swallowed.

### Fixed

- **Library empty on launch when refresh-on-startup is off** — Previously discovered books (local and Drive) now load from cache on app open even when automatic rescan is disabled. Only the Drive network sync is skipped.

### Internal

- Extracted `PositionPersister`, `CastController`, `DriveRemovalScheduler`, and `MediaStateBroadcaster` out of `AudioVaultHandler`. PRD-12 archived.
- Extracted pure helpers from `LibraryScreen` (status filter, last-played sort, byte formatting) and `DriveDownloadManager` (queue-selection decision). Scanner recursion depth named, `unawaited` standardised, position-service status derivation DRY'd.
- 52+ new tests across Drive services, book repository, and player helpers. No behaviour change.

---

## [1.2.5] — 2026-04-16

### Added

- **Background library resync** — Existing books stay visible while a rescan runs. Local books stream into the list one by one as the scanner finds them; Drive books merge in at the end. Stale books are removed and the list re-sorts once at completion. The player remains fully accessible throughout.
- **Refresh library on startup** — New toggle in Settings (off by default). When off, the app opens instantly with no scan; tap the refresh button to scan manually. When on, a full scan runs every time the app opens.
- **Deep folder nesting** — The scanner now supports author/series grouping folders up to three levels deep (e.g. `Audiobooks / Author / Series / Book`), so libraries organised with an extra folder layer are fully indexed.
- **Book details screen** — Long-press a book to open a details sheet showing cover, title, author, format, file count, and total duration. Drive books include download/remove controls.

### Changed

- **Sync indicator** — The full-width `LinearProgressIndicator` bar is replaced by a spinning refresh icon in the AppBar, keeping the visual footprint minimal while a rescan is in progress.

### Fixed

- **Drive: cover preserved on undownload** — Removing a downloaded Drive book no longer clears its cover art in the library list.
- **Drive: stale download queue cleared on re-download** — Pending file entries from a previous failed download are removed before starting a fresh download attempt.
- **Drive: cover-only overlay** — Download progress overlay on book cards is now suppressed for cover-file events so it doesn't flash "downloaded" prematurely.
- **Drive: auto-retry failed downloads** — Individual file downloads retry up to 3 times before marking as failed; a 30-second per-chunk timeout prevents stalled transfers from blocking the queue.
- **Drive: onboarding** — Selecting only a Drive folder on first launch no longer shows "No library folder set".

---

## [1.2.0] - 2026-04-12

### Added

- **Book status tracking** — Each book is automatically tracked as Not started, In progress, or Finished. Status is derived from playback position for existing books and stored explicitly once set.
- **Status filter pills** — Filter the library by Not started, In progress, or Finished.
- **Finished badge** — A checkmark badge appears on book covers and list tiles for finished books.
- **Drive: Remove when finished** — New toggle in Settings. When enabled, downloaded audio files are deleted 1 minute after a book finishes, freeing storage while keeping the book in the library as Finished.
- **Disable autoplay on open** — Opening the player screen no longer auto-starts playback.

### Changed

- `PositionService` migrated to DB schema v3, adding a `status` column to the `positions` table.

---

## [1.1.0] — 2026-04-11

### Added

- **Library search** — Filter books by title or author with an inline search bar.
- **Fine-grained playback speed** — Speed chip opens a dialog with a 0.5×–3.0× slider and quick-select chips. Live preview while dragging; Cancel reverts.
- **Custom skip interval** — New "Skip interval" setting (10 / 15 / 30 / 45 / 60 s).
- **Custom sleep timer** — "Custom…" option opens a 1–180 minute picker.

### Fixed

- **Player times blank on reopen** — Reopening the player for a paused book now shows the correct elapsed time, remaining time, and scrubber position immediately.

### Changed

- **Auto-rescan on folder change** — Changing the audiobooks folder in Settings triggers a library rescan immediately.
- **Enrichment cache flush on rescan** — When enrichment is disabled, rescanning ignores previously cached covers and reverts books to embedded artwork.

---

## [1.0.3] — 2026-04-09

### Added

- **About screen** — App info, licences, and links accessible from the bottom of Settings.
- **App icon** — Custom vault-door icon across all Android mipmap densities with adaptive foreground layer.

### Fixed

- **`path_provider_android` pinned to 2.2.23** — Prevents NDK-dependent versions from crashing the scanner at runtime.

---

## [1.0.2] — 2026-04-08

### Added

- **Smart rewind on resume** — Playback automatically rewinds when you resume after a break: 10 s after 5 min, 15 s after 1 hour, 30 s after 24 hours.
- **Full Cast playback routing** — All playback controls route to the Cast device when a Cast session is active.
- **VPN warning in Cast picker** — A warning banner is shown when a VPN connection is detected.

### Fixed

- Chapter index off-by-one at boundaries; mini player position during Cast; hidden files excluded from scan.

---

## [1.0.1] — 2026-04-06

### Added

- **Google Cast support** — Stream to any Chromecast or Cast-enabled speaker from the player.
- **M4B chapter support** — Single-file M4B audiobooks with embedded QuickTime chapter tracks display a navigable chapter list.
- **Light/dark/system theme** — Color mode setting persisted and applied live.
- **Metadata enrichment** — Background cover art fetching from Open Library for books without artwork.

### Fixed

- Chapter time labels; M4B chapter parsing; natural file sort; sleep timer off-by-one; mini player progress; history screen unreachable; playback completion position save.

---

## [1.0.0] — 2025

Initial release.

- Audiobook library scanner (folder-based, M4B/MP3/FLAC/etc.)
- Full-screen player with chapter list and progress scrubbing
- Mini player in library grid/list view
- Resume playback from last position (SQLite persistence)
- Sort library by last played / alphabetical
- Firebase Analytics & Crashlytics (opt-in, consent gate)
- Android: `MANAGE_EXTERNAL_STORAGE` for full file system access
