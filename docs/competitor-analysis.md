# Competitor analysis: Paste 7.0.2 and PastePal 2.21.7

Static + light live observation on 2026-10-18. Method: REA (`rea-agents` 6.7.0)
for signature/plist/schema inspection, plus `otool`/`strings` on a thinned
arm64 slice. Both apps were run and fed an identical seven-item probe set.

Evidence IDs are recorded in the REA session; no decompiler was available, so
every conclusion below is from packaging metadata, linked frameworks, stored
schemas, and observed stored data — never from pseudocode.

## Shape of both apps

| | Paste 7.0.2 | PastePal 2.21.7 |
|---|---|---|
| Bundle | `com.wiheads.paste` | `com.onmyway133.PastePal` |
| Team | 4788TTJ39Y | T78DK947F2 |
| Sandbox | yes | yes |
| Hardened runtime | yes | yes |
| `LSUIElement` | yes (menu bar) | yes (menu bar) |
| Min macOS | 14.0 | 14.0 |
| Storage | Core Data → SQLite | Core Data → SQLite |
| Sync | CloudKit (private DB + shared zones) | CloudKit **and** CloudDocuments |
| Local network | `network.client` + `network.server` | same + Bonjour `_pastepal._tcp/_udp` |
| Extra process | `Paste Helper.app` (`LSBackgroundOnly`) | none |
| Analytics | PostHog, Sentry | none |

Both are Mac App Store builds (`_MASReceipt` present, App Store-specific
licensing bundle for Paste).

## Paste: schema and MCP server

**Core Data model** lives in `PastePackages_PasteCore.bundle`, at **v11** with
11 historical versions plus a `.cdm` class-definition model. Entities:

```
ItemEntity      timestamp, checksum, title, rawPreview (blob),
                displayOrderInPinboard, rawType, data, device,
                list, sourceApplication, isIndexedBySpotlight
ItemDataEntity  rawPasteboardItems (blob) -> {types, dataByType}
ListEntity      rawAttributes, rawShareRecord     <- pinboards
ListMetadataEntity / ObjectMetadata / ObjectShare / ObjectPendingMapping
ApplicationEntity / DeviceEntity
```

`ZOBJECTMETADATA` (cloudKitRecordName, cloudKitZoneName, objectURI,
isPendingDeletion) plus `ZOBJECTSHARE` confirms `NSPersistentCloudKitContainer`
with CKShare for shared pinboards.

**Dedupe key confirmed empirically.** `ZCHECKSUM` is 32 hex characters, and
hashing the archived plain-text payload reproduces it exactly:

```
payload   "Pin items to pinboards ... across all devices."
md5       8c95be7b9ab859ca4215d6845299c609
ZCHECKSUM 8c95be7b9ab859ca4215d6845299c609   ✓
```

No trailing newline, MD5 of the *plain text only* — not of the typed blob set.

**Stored payload shape.** `ZRAWPASTEBOARDITEMS` is an `NSKeyedArchiver` archive
of `{types, dataByType}`. Probe rows show exactly the types an app advertised:

```
item 13  types=[public.file-url]                          file:///etc/hosts
item 14  types=[public.tiff]                              40×40 teal PNG-as-TIFF
item  9  types=[public.utf8-plain-text]                   #FF8800
```

**MCP server** is an isolated SwiftPM module, `PastePackages_PasteMCP.bundle`
(identifier `packages.PasteMCP.resources`, containing only `paste-icon.png`).
Tool classes recovered from the binary:

| Class | Tool name |
|---|---|
| `SearchTool` | `search` |
| `ReadItemTool` | `read_item` |
| `CreateItemTool` | `create_item` |
| `UpdateItemTool` | `update_item` |
| `DeleteItemTool` | `delete_item` |
| `ListPinboardsTool` | `list_pinboards` |
| `CreatePinboardTool` | `create_pinboard` |
| `RenamePinboardTool` | `rename_pinboard` |
| `DeletePinboardTool` | `delete_pinboard` |
| `AddItemToPinboardTool` | `add_item_to_pinboard` |
| `RemoveItemFromPinboardTool` | `remove_item_from_pinboard` |

The MCP implementation is **SwiftNIO** (`_TtCO9NIOExtras17NIOJSONRPCFraming31ContentLengthHeaderFrameEncoder`
confirms NIOJSONRPC framing, and `NIOPosix`/`NIOFileSystem` bundles ship
alongside). Transport is **SSE** with reconnection and `Last-Event-ID` resume.
Auth is a **full OAuth 2.0 authorization-code server** implemented in-app
(`PasteMCP.OAuthAuthorizationCodeFlowing`, `.well-known/oauth-authorization-server`
discovery, loopback allowance, state-mismatch and redirect-URI-mismatch checks) —
considerably more than the "server URL + token" the marketing implies.

Design details worth stealing:
- **Search returns summaries only.** `id, type, preview, timestamp, app, device`;
  `timestamp` is "when the item entered clipboard history" and is *absent* for
  pinned-only items. Full content needs `read_item`. Capped at 100 matches.
- **Destructive tools are two-step.** Call without `confirm` to preview, then
  with `confirm: true`. `delete_item` removes from history *and* its pinboard.
- **`create_item` never writes the system clipboard** — it only records.
- Type auto-detection is documented in the tool description as
  `text` / `color` (6-digit hex) / `link`, matching what we already do.

Also linked: `FoundationModels.framework` (on-device LLM, for the "Intelligent
Clipboard"), `ScreenCaptureKit` + `NSScreenCaptureUsageDescription` (reads the
target window to suggest the right clip, never stored), `CoreSpotlight`,
`Metal`, `WebKit`, `MetricKit`, `libcompression`, `AppIntents`, `StoreKit`.

## PastePal: schema and features

**Core Data model** is `PastePal2.momd/Butter.mom` — a single entity, and far
more explicit about content type than Paste's:

```
Butter  string, blob, itemType, name, color, icon, collectionId, locked,
        markedDelete, device, deviceId, createdAt,
        contentColor, contentEmoji, contentRichTextData,
        contentFileUrl, contentFileBookmark, contentFileSize,
        contentImageFileUrl/Width/Height,
        contentLinkUrl/Title/Description/ImageUrl,
        contentMFilesArrayUrl, contentMFilesFirstBookmark,
        appBundleId, appName, appUrl, pbType
```

Live table `ZCDCLIPBOARDITEM` mirrors this plus `ZISPINNED`. Two fields `copyz`
lacks and should adopt: **`ZLOCKED`** (a stronger state than pinned — survives
clear) and **`ZMARKEDDELETE`** (tombstone for sync, so a delete propagates
instead of resurrecting on another machine).

Linked frameworks: `MultipeerConnectivity` + Bonjour services for the "Peer
Share" LAN feature, `Lottie` (animations), `PDFKit`, `QuickLookThumbnailing`,
`QuickLookUI`, `Vision`, `WidgetKit`, `AppIntents`, `JavaScriptCore`,
`libswift_StringProcessing` + `RegexBuilder`, `UniformTypeIdentifiers`,
`AdServices`, `Photos`/`PhotosUI`, `AVFoundation`/`AVFAudio`. Also carries
`NSBonjourServices` = `_pastepal._tcp`, `_pastepal._udp` and
`NSLocalNetworkUsageDescription` ("Enable local network discovery to use Peer
Share").

It honours the same three `org.nspasteboard.*` privacy markers as Paste, plus
`com.apple.is-remote-clipboard` for Handoff.

## Where `copyz` differs, and what to change

Confirmed by running all three on one identical probe set (plain text, hex
colour, URL, emoji, Swift code, single file, TIFF image). All three captured
all seven. Type granularity is equivalent.

| | copyz | Paste | PastePal |
|---|---|---|---|
| Storage | SQLite + FTS5 trigram | Core Data (SQLite) | Core Data (SQLite) |
| Dedupe key | order-independent SHA-256 over all typed blobs | MD5 of plain text only | none visible |
| Full-text search | FTS5, substring | CoreSpotlight + index | none |
| Portability | Markdown vault, any sync folder | CloudKit only | CloudKit/CloudDocuments |
| Analytics | none | PostHog + Sentry | none |

Genuinely better in `copyz`, and worth keeping:
- **Dedupe is stricter.** SHA-256 over the typed blob set catches a copy whose
  types changed but text did not, which MD5-of-plain-text cannot. The
  order-independent sort also survives a source app reordering its type list.
- **Search is in-process.** FTS5 trigram means `createTab` finds `createTable`;
  Paste delegates to Spotlight, which cannot be assumed to behave the same when
  the app is sandboxed and the index is cold.
- **No server dependency.** The vault folder works offline and syncs through
  whatever client the user already runs.

Gaps worth closing, in priority order:

1. **A `locked` state distinct from pinned.** PastePal's `ZLOCKED` survives
   "clear history"; ours only exempts from retention. Cheap to add, and it is
   the single most-requested behaviour in every clipboard manager's issue
   tracker.
2. **Tombstone deletes (`ZMARKEDDELETE`).** Our vault import is read-only, so a
   clip deleted on machine A reappears on machine B. Needs a tombstone list in
   the sidecar, checked during import.
3. **Two-step confirm on destructive MCP-style tools** — relevant only if we
   ever add an MCP surface, and Paste's is the better design of the two.
4. **`displayOrderInPinboard`** — Paste stores explicit ordering inside a
   pinboard; ours is timestamp-only.

Not worth pursuing: CloudKit sync (needs a paid team, an entitlements
migration, and would defeat the "point it at any folder" property), on-device
LLM suggestions (needs `FoundationModels` availability and a design we have no
basis for yet), and screen-capture context (privacy cost is high, value is
marginal).

## Unverified

- No decompiler was installed, so **no claim here rests on decompiled code**.
  Function-level behaviour — the actual polling interval, the exact type
  classification rules, search ranking — is unconfirmed and observable only
  through behaviour.
- Paste's MCP server was not exercised live; it is not enabled by default and
  its listener did not appear in `lsof`. Tool surface came from the binary's
  embedded descriptions and Swift class names, which is strong but not
  equivalent to calling the tools.
- PastePal's `Butter` model is a single entity, but whether it keeps multiple
  rows per copy (multi-item pasteboards) is untested — its
  `contentMFilesArrayUrl` suggests one row holds all files, which would match
  our merge behaviour.