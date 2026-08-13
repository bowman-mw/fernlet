# ``FernletShareExtension``

The share-sheet extension that sends a recipe web page from Safari (or any sharing app) into Fernlet's import queue.

## Overview

FernletShareExtension is a `com.apple.share-services` app extension. Its `NSExtensionActivationRule` accepts either shared plain text or a single web URL, so it appears in the share sheet for web pages and for copied links shared as text. The principal class, ``ShareViewController``, presents no interface of its own: on appearance it flattens the share payload's attachments, prefers `UTType.url` items and falls back to plain-text items that parse as URLs, then hands the result to ``SharedRecipeImportQueueWriter`` and completes the request. If no usable URL is found, or the URL is not `http`/`https`, the request is cancelled and the system share UI shows the error text.

The hand-off to the main app is a file in the shared App Group `group.MBO.Fernlet`: a JSON array of ``SharedRecipeImportRecord`` values at `SharedRecipeImports/PendingRecipeURLs.json`, written atomically with file protection until first user authentication. The extension only ever appends fresh records (re-sharing a URL replaces its earlier record); the app side reads the same file through `SharedRecipeImportQueue` in the `AppServices` module of FernletKit, and `FernletStore.processSharedRecipeImportQueue()` drains it on launch and on each foreground — importing each URL, removing records that succeed, counting attempts against a five-try budget for records that fail, and deferring records that hit the daily AI budget.

A deliberate constraint shapes this target: it links no FernletKit modules at all (its package-product dependency list is empty), keeping the extension's footprint minimal and keeping it structurally distant from the app's sealed stores. The cost is that ``SharedRecipeImportRecord`` is a hand-maintained mirror of the app-side record type — the JSON schema is shared by convention, not by a common source file, so field changes must be made on both sides or data is dropped when the extension rewrites the queue. The extension's file access is also uncoordinated (no `NSFileCoordinator`), relying on atomic writes alone, whereas the app side coordinates every read and write.

Two private error types back the user-facing failure copy: `ShareExtensionError` (no URL found in the payload) and `QueueWriterError` (non-web URL rejected by the writer).

## Topics

### Share-sheet entry point

- ``ShareViewController``

### Import-queue hand-off

- ``SharedRecipeImportQueueWriter``
- ``SharedRecipeImportRecord``
