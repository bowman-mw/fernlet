# Fernlet
 
**A tamagotchi of yourself.** A small companion on your home screen whose appearance reflects how you've been treating yourself — not how optimized you've been.
 
Feed it when you eat, rest it when you sleep, take it outside when you move.
 
---
 
Fernlet is an iOS health app built around one idea: consistent-enough self-care is better than perfect self-care. No streaks. No calorie targets. No comparisons. Just a small creature that notices when you've been taking care of yourself, and gently notices when you haven't.
 
## Philosophy
 
Most health apps are optimization tools. Fernlet isn't. The goal isn't a perfect score — it's a life where you eat enough, sleep enough, move enough, and check in with yourself often enough that the little character on your screen generally looks okay. Some weeks it thrives. Some weeks it's tired. That's fine. That's life.
 
Every design decision in this app is audited against a set of axioms:
 
- **Enough, not everything.** Consistent self-care over daily optimization.
- **No streaks.** Missing a day lowers that day's score and nothing else. Every unlock is cumulative and non-resettable.
- **No calorie targets.** Macro goals only. No weight targets, no body composition tracking.
- **Privacy by architecture.** Sensitive data (period tracking, photos, sensitive memory) is walled off at the Swift module boundary — compile-time enforced, not convention-enforced.
- **Fuzzy social signals.** Friends see vibes, never numbers.
- **Gentle gamification.** The tamagotchi reacts; it doesn't punish.
- **Real connections, in person.** Friend-related features require physical co-location via proximity handshake.
- **Gentlest exactly when life is hardest.** Sickness softens scoring. Hard journal days still count.
## Features
 
- **Companion avatar** whose appearance reflects your rolling 24-hour wellness score — thriving, okay, tired, or fainted
- **Food logging** with macro tracking (protein, carbs, fat) — no calorie number, ever
- **Exercise logging** with Apple Watch and HealthKit integration
- **Sleep tracking** via HealthKit with derived quality scoring
- **Hydration logging** with a satisfying container-fill visual
- **Hygiene tracking** — simple daily toggles
- **Journaling** with color tags and a calendar heatmap — ≤100 words, zero friction
- **Period tracking** in a fully walled-off module that never touches any AI system or cloud service
- **Photowall** — Polaroids-on-a-string behind your avatar, populated from in-person hangouts
- **Friend system** capped at 8 friends, added only via in-person proximity handshake (UWB)
- **Shared activities** with cascading group trust
- **On-device AI** via Apple Foundation Models for workout suggestions, meal planning, journal memory, and coaching tone
- **Creation Studio** — draw and publish custom clothing items for your companion
## Privacy Architecture
 
Privacy in Fernlet is enforced by the Swift module import graph, not by code review or convention.
 
- **Period data** lives in `PrivateHealthStore` and is unreachable by `ContextBuilder`, `OHTTPProvider`, or any AI module. Period-derived signals flow through `PeriodContextBridge` to on-device AI only — never to third-party providers.
- **Sensitive Memory** (emotional patterns, relationship context, intimacy context) lives in `PrivateMemoryStore`. It is never transmitted off-device, never browsable by the user, and structurally unreachable by `OHTTPProvider`.
- **Photos** live in `PrivateMediaStore` and are never sent to any AI model, on-device or cloud.
- **Third-party AI** is off by default for every feature, routed through Oblivious HTTP when enabled, and structurally cannot receive period data, sensitive memory, or photos.
- **Cloud footprint is minimal** — only friend fuzzy states, friend links, and activity rosters. No health metrics, no content, no scores.
See [Specifications](./docs/Fernlet___Specifications.md) for the full module boundary diagram and data flow documentation.
 
## Tech Stack
 
- **iOS 26+**, iPhone 15 Pro or later for full AI features
- **SwiftUI** and **SwiftData**
- **Apple Foundation Models** — on-device AI (stateless inference, no fine-tuning, no persistent model state)
- **HealthKit** — reads heart rate, sleep, active energy, workouts; writes workout samples back
- **NearbyInteraction (UWB)** — centimeter-scale proximity for friend handshakes (iPhone 11+, excluding SE/e models)
- **Core Bluetooth** — discovery and data exchange layer for the proximity handshake
- **WeatherKit** — mood-recovery prompt context
- **Vision + Core ML** — meal photo analysis, moderation classifiers
- **CryptoKit** — Ed25519 identity keypairs, iCloud Keychain sync
- **Oblivious HTTP** — optional third-party AI routing (Claude / OpenAI)
## Build Phases
 
Development is organized into four phases:
 
| Phase | Scope |
|---|---|
| **Phase 1** | Core loop — all logging, scoring, avatar, milestones. No AI, no cloud. |
| **Phase 2a** | Cloud backend — friend states, hearts, activities. |
| **Phase 2b** | Proximity handshake — UWB integration, friend-add flow, shop access. |
| **Phase 3** | On-device AI — Foundation Models integration, memory system, Creation Studio publish. |
| **Phase 4** | Off-device AI — OHTTP gateway, per-feature third-party opt-in, audit log UI. |
 
See [Build Phases](./docs/Fernlet___Build_Phases.md) for the full breakdown.
 
## Documentation
 
- [`Fernlet — Specifications`](./docs/Fernlet___Specifications.md) — full product specification including data model, scoring formula, privacy architecture, AI layer, and every feature
- [`Fernlet — Build Phases`](./docs/Fernlet___Build_Phases.md) — phased implementation plan
- [`Fernlet — Design System`](./docs/Fernlet_Design_System.md) — visual design language, color palette, typography, component notes
## Status
 
Early development. Phase 1 in progress.
 
---
 
*fernlet.com*
