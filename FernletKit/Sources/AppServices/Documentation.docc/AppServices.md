# ``AppServices``

Assorted iOS platform-service shims — Vision food capture, nutrition-label OCR, local notifications, the App-Group recipe-import queue, and WeatherKit ambience — kept out of the app target so the features they back are module-testable.

## Overview

`AppServices` is the Layer-6 "[S] platform shims" grab-bag of the FernletKit carve-up: small, mostly stateless services that wrap an Apple framework (Vision, CoreImage, UserNotifications, WeatherKit, CoreLocation, `NSFileCoordinator`) behind types the app and unit tests can hold without touching that framework directly. Nothing here owns durable app state — the one file this module writes (the pending-recipe JSON) is a hand-off queue, not a store — and nothing here renders UI; the SwiftUI surfaces that consume these services (`FoodCaptureRouter`, `NutritionLabelCameraSheet`, `BarcodeScanView`, `HomeView`, `SettingsSheet`, `ContentView`, and friends) all live in the app target.

The food-capture half is three parallel pipelines feeding the app's single meal-logging cascade. ``BarcodeScanner`` (with the ``BarcodePayloadDetecting`` seam and its production conformer ``VisionBarcodeDetector``) reads retail product barcodes off still photos, sharing its symbology list with the app's live VisionKit scan path. ``NutritionLabelScanner`` is the deepest pipeline: CoreImage perspective-correction and contrast preprocessing, Vision text recognition primed with label vocabulary, then a pure, heavily fuzz-tolerant line parser producing a ``NutritionLabelResult`` (including dual-column "as prepared" labels via ``DualColumnScanResult``, and %-Daily-Value back-solving against the shared `FDADailyValues` table in `FernletDomainModel`). ``VisionFoodImageClassifier`` (behind ``FoodImageClassifying``) labels whole meal photos on-device, and the pure ``FoodImageTaxonomy`` filters those labels down to concrete foods and composes the short description the store's meal resolution consumes. In every pipeline the Vision work runs in a detached task and the parsing/filtering logic is pure, which is what makes the `NutritionLabelScannerTests` / `MealPhotoRecognitionTests` suites possible without a camera.

The remaining services are independent of one another. ``NotificationService`` is the app's entire local-notification surface (authorization, the opt-in gentle daily check-in, and the best-effort mesh session-message ping); its notable invariant is that the pending notification request itself is the persisted check-in preference — there is no shadow flag to drift. ``SharedRecipeImportQueue`` is the `NSFileCoordinator`-guarded App-Group JSON file through which the `FernletShareExtension` hands shared recipe URLs to the app; `FernletStore` drains it on launch/foreground with retry, budget-deferral, and delete-everything semantics captured on the type. ``WeatherKitService`` provides the opt-in, privacy-lean weather surfaces (mood-recovery prompt, walk-friendliness ``WeatherComfort``, Home-ambience ``WeatherAmbient``): coarse location only, a shared 30-minute conditions cache, coalesced in-flight requests, and `nil` on every failure so weather can never block or nag.

**Position relative to the S3 wall:** `AppServices` sits entirely outside the sealed side — its only in-package dependencies are `FernletDomainModel` and `AIProviders`, and it never touches a `Private*` store. The `AIProviders` edge is wall-legal and points *downward* (toward the walled module, not from it); it exists solely so the `RecipeDefinition(importedRecipe:)` bridge in this module can consume `AIProviders`' `ImportedRecipe` when a queued web import lands. Nothing in this module can widen the wall: the wall constrains what `AIProviders`/`CloudKitSync` may import, and this module only gives them nothing.

**Concurrency:** the target deliberately has no `defaultIsolation(MainActor.self)` — isolation is mixed per type. ``WeatherKitService`` is an explicitly `@MainActor` singleton whose CoreLocation delegate callbacks hop back to the main actor; everything else is `nonisolated` value types, protocols, or caseless namespaces whose async statics detach for Vision/CoreImage work. Privacy posture is uniform: all image analysis is fully on-device, the weather types are stripped to booleans and a coarse sky bucket before leaving the service, and notification content re-sanitizes any peer-supplied name defensively.

## Topics

### Barcode capture

- ``BarcodePayloadDetecting``
- ``VisionBarcodeDetector``
- ``BarcodeScanner``

### Meal-photo classification

- ``FoodImageClassifying``
- ``VisionFoodImageClassifier``
- ``FoodImageClassification``
- ``FoodImageTaxonomy``

### Nutrition-label scanning

- ``NutritionLabelScanner``
- ``NutritionLabelResult``
- ``DualColumnScanResult``
- ``NutritionLabelScanError``

### Shared recipe imports

- ``SharedRecipeImportQueue``
- ``SharedRecipeImportRecord``

### Notifications

- ``NotificationService``

### Weather and ambience

- ``WeatherKitService``
- ``WeatherComfort``
- ``WeatherAmbient``
- ``AmbientSky``
