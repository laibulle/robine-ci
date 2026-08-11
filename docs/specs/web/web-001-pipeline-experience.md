# WEB-001 — Pipeline experience

## Status

- **State:** Accepted
- **Owner:** Web
- **Target:** MVP
- **Last updated:** 2026-08-11

## Summary

The Phoenix LiveView interface provides complete setup, repository, workflow, pipeline, job, and administration experiences. Its central interaction is a live, navigable execution view that makes failure location and local reproduction obvious.

## Problem

CI interfaces often reduce execution to an undifferentiated log stream. Users need to understand the graph, current activity, failure reason, and next action without refreshing, guessing, or navigating through unrelated output.

## Goals

- Make current and failed execution state understandable at a glance.
- Stream logs efficiently without sacrificing navigation or accessibility.
- Expose complete MVP administration without requiring database or shell access.
- Use consistent URLs that can be deep-linked from GitHub and the CLI.

## Non-goals

- A drag-and-drop workflow editor.
- A general observability platform.
- Mobile-native applications.
- Arbitrary dashboard customization.

## Users and use cases

### Primary user

A developer diagnosing a build and an operator configuring repositories, identity, secrets, and retention.

### Use cases

1. Complete first-run setup and connect GitHub.
2. Browse repository workflows and recent pipelines.
3. Watch a pipeline and its logs live.
4. Cancel a run, retry a job, and copy a local reproduction command.
5. Configure instance and repository settings.

## Requirements

### Functional requirements

- **FR-1:** The UI MUST provide first-run setup, sign-in, repository selection, workflows, pipeline history, pipeline detail, job detail, secrets, identity, and instance health pages.
- **FR-2:** Pipeline detail MUST show the job dependency graph, status, duration, commit, trigger, and actor.
- **FR-3:** Job detail MUST group logs by execution phase and step and stream new output without full-page refresh.
- **FR-4:** Users MUST be able to expand, collapse, search, and deep-link to a step.
- **FR-5:** On failure, the first failing step MUST be emphasized and its relevant terminal output brought into view without hiding preceding context.
- **FR-6:** Authorized users MUST be able to cancel active pipelines and retry failed or cancelled jobs after confirmation.
- **FR-7:** A retry MUST show whether prerequisite artifacts are available; it MUST refuse with a precise reason when required inputs have expired.
- **FR-8:** Job pages MUST provide a copyable local reproduction command and list CI-only inputs that are omitted locally.
- **FR-9:** Log virtualization or pagination MUST prevent unbounded browser memory use.
- **FR-10:** URLs MUST remain stable across real-time state transitions.
- **FR-11:** Pipeline history MUST expose repository, workflow, source reference when retained, immutable commit, trigger, actor, durable or elapsed duration, status, start time, and the first failed job when known without requiring detail navigation.
- **FR-12:** Pipeline history MUST support URL-persisted search plus status and repository filters over a bounded recent result window.
- **FR-13:** Repository catalogue entries MUST expose provider, trust, integration-health state, active-run count, previously run workflow count, last activity, and latest pipeline outcome.
- **FR-14:** Repository pipeline history MUST use a repository-scoped query rather than filtering a global recent window and MUST link to the global cockpit with the repository filter preserved.
- **FR-15:** Repository schedule discovery MUST show a human-readable UTC recurrence, bounded next-occurrence preview, active state, and latest retained scheduled-run outcome when known.
- **FR-16:** The authenticated Robine product MUST expose its compile-time version, commit, source reference, build timestamp, pipeline ID, and trigger without requiring access to the CI control plane.

### UX requirements

- **UX-1:** Core pages MUST meet WCAG 2.2 AA for keyboard navigation, focus, contrast, labels, and status not conveyed by color alone.
- **UX-2:** Every empty, loading, disconnected, degraded, and error state MUST be explicitly designed.
- **UX-3:** LiveView reconnects MUST restore the current view and request only missing log segments.
- **UX-4:** Destructive or costly actions MUST use clear confirmations and prevent duplicate submission.
- **UX-5:** The interface MUST be responsive down to a practical phone viewport, while desktop remains the primary log-analysis target.
- **UX-6:** Active and recently failed pipelines MUST be elevated above ordinary history, while the remaining runs are grouped chronologically and remain available in a compact scan-friendly layout.
- **UX-7:** Pipeline history rows MUST provide one clear full-row navigation target, relative time with an exact accessible timestamp, and explicit live refresh, retrying, filtered-empty, and result-window feedback.
- **UX-8:** The repository catalogue MUST prioritize connected-project activity over provider provisioning and MUST support URL-persisted search, provider, and attention filters.
- **UX-9:** Connecting a repository MUST be a progressive administrator-only flow with explicit provider selection, available-repository search, and confirmation that trusted workflow code may execute.
- **UX-10:** Repository detail MUST present an operational overview and recent pipelines before integration settings, manual runs, schedules, and historical workflow names, with stable section navigation.
- **UX-11:** Manual launch MUST resolve the default branch when no branch is entered, require explicit selection for required choice inputs without defaults, associate validation errors with fields, summarize the immutable revision in a confirmation, and prevent duplicate submission.
- **UX-12:** Product build provenance MUST appear as a low-emphasis support footer linked to one clearly labelled detail page; it MUST not compete with primary CI navigation.
- **UX-13:** Primary navigation MUST expose the active section with a non-color-only visual treatment and `aria-current`; mobile navigation MUST reserve its limited height for primary destinations.
- **UX-14:** Authenticated pages MUST share one heading hierarchy, and nested pipeline, job, repository, secret, and workflow-revision views MUST expose consistent breadcrumbs.
- **UX-15:** Administration MUST separate overview, runners, source control, security, and users into URL-addressable work areas instead of rendering one continuous control surface.
- **UX-16:** Destructive controls MUST be confirmed and visually separated from routine actions. Product surfaces MUST use the shared radius hierarchy: panel, list item, then control.
- **UX-17:** Robine MUST retain a recognizable but restrained product character through warm neutral surfaces, petroleum dark surfaces, teal and mineral-amber accents, the diagonal geometry of the `R`, and precise human microcopy. The husky reference MUST remain confined to the logo's negative space.
- **UX-18:** The desktop sidebar MUST act as a Robine control column with a clear brand lockup, contextual destination descriptions, a simple monochrome active signal, low-emphasis provenance, and a distinct account area.

### Operational requirements

- **OR-1:** Initial job pages MUST not load the full log into server or browser memory.
- **OR-2:** Live log delivery MUST use sequence cursors and support reconnection without duplication.
- **OR-3:** Server-rendered pages SHOULD expose meaningful content before LiveView connects.
- **OR-4:** Tailwind usage MUST follow a documented design-token layer rather than ad hoc colors and spacing.

## Proposed design

The UI follows the semantic token and component contracts in `docs/design-system.md`. Light and dark themes implement the palette, while product templates consume intent-level surface, content, action, and status semantics. All interactive controls share a visible keyboard focus treatment, status text never depends on color alone, and operating-system reduced-motion preferences override decorative transitions.

The primary navigation contains Repositories, Pipelines, and Administration and exposes the current section in desktop and mobile layouts. Nested operational views use consistent breadcrumbs. Repository pages show integration health, workflows, recent runs, secrets, and settings. Pipeline pages use a compact graph on desktop and an ordered dependency list on small screens.

Pipeline history is an operational cockpit rather than a gallery. A bounded 50-run projection is searchable by workflow, repository, source reference, or commit and filterable by status and repository; non-default filters are encoded in the URL. Active pipelines and failures from the last 24 hours appear in a dedicated watchlist. Remaining results form a compact, date-grouped history. Every row exposes the repository and workflow, source reference when known, exact commit abbreviation, actor, trigger, elapsed or durable duration, relative age, exact machine-readable timestamp, first failed job when applicable, and a full-row detail link. Polling retains the last known projection during transient errors and reports whether results are current or retrying.

The repository catalogue is a project-operations surface. Connected repositories appear before a collapsed administrator-only connection flow and are searchable and filterable through URL state. Every full-row navigation target distinguishes durable trust from current integration health and summarizes active runs, previously executed workflows, last activity, and latest outcome. Provider discovery uses an explicit provider selector, filters large catalogues, and confirms the execution authority granted by trust.

Repository detail starts with trust, health, provider, operational statistics, and the repository-scoped recent pipeline projection. Stable section links lead to manual execution, schedules, integration checks, secrets, and explicitly labelled historical workflow names. Manual runs display the resolved immutable revision and require confirmation after input validation. Schedule cards pair the raw cron contract with a human description, bounded next occurrence, active state, and latest retained scheduled execution.

Robine embeds its own `ROBINE_BUILD_*` values at compile time. The authenticated navigation renders a discreet version/reference footer at the bottom of the desktop sidebar; mobile exposes the same detail page through a compact information action in the application header so provenance does not compete with primary navigation. A dedicated Build information page exposes the complete immutable values for support and deployment verification. Development builds expose a complete, clearly labelled placeholder dataset so the integration remains visible and testable without CI provenance.

Administration uses five URL-addressable work areas: Overview, Runners, Source control, Security, and Users. Repository detail retains its operational ordering while its section navigation remains visible during long-page scrolling. Shared page-heading and breadcrumb components keep information hierarchy stable across catalogue and detail views.

The MVP graph representation is an accessible dependency-ordered list: every job names its prerequisites, durable status, latest runner phase, elapsed duration, and terminal reason. Pipeline metadata persists the source trigger, initiating actor, exact commit, execution start, and terminal finish. Runner-loss and system-failure reasons are elevated as infrastructure failures and are visually and textually distinct from repository command failures and timeouts. This list is the canonical accessible graph; a decorative node-edge rendering may be layered on later without replacing it.

The log viewer stores neither all output in a LiveView socket nor all rendered nodes in the browser. It requests bounded segments by sequence cursor, appends live events, and offers server-side search. ANSI output is sanitized and rendered through a restricted parser. Authorized users can download the retained combined log or exact stdout/stderr streams as files; downloads use the same durable segments and retention policy as the live viewer.

Every persisted log segment carries an explicit runner phase (`image_acquisition`, `service_preparation`, `execution`, or `cleanup`) in addition to its step position. The job page renders phase sections containing expandable step groups; both levels have stable anchors, and search preserves the phase context of every match.

The log navigation performance fixture persists exactly 100,000,000 bytes and verifies that initial navigation renders at most 50 × 64 KB segments, produces less than 4 MB of HTML, and keeps the LiveView process below 30 MB. Automated semantic smoke checks cover setup, sign-in, navigation, history, and pipeline detail: one main landmark and page heading, unique IDs, named navigation and controls, labelled form fields, image alternatives, and textual status labels.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| LiveView disconnects | A connection banner appears; existing content remains readable | Reconnect and fetch events after last cursor |
| Log segment unavailable | Retention/availability message replaces silent blank output | Download available archive or rerun |
| Retry inputs expired | Retry is blocked with named missing artifacts | Rerun dependencies or entire pipeline |
| GitHub degraded | Local state remains visible with integration warning | Automatic integration recovery |

## Security and privacy

All pages enforce server-side authorization. Logs are treated as sensitive repository data, sanitized before HTML rendering, and protected from cross-site scripting. Secret values are never returned to the browser after creation.

## Observability

Measure LiveView connection count, reconnect rate, page latency, log segment latency, client payload sizes, failed actions, and time from job failure to first log view.

## Acceptance criteria

- [x] A user can complete all MVP administration through the UI.
- [x] A running job updates without manual refresh and reconnects without duplicate log lines.
- [x] A 100 MB test log can be navigated without loading 100 MB into a LiveView process or browser DOM.
- [x] A failed step is apparent from the pipeline page and directly linkable.
- [ ] All core journeys pass automated keyboard and accessibility checks, plus a manual screen-reader smoke test.
- [x] Retry clearly handles present and expired dependency artifacts.
- [x] Pipeline history supports URL-persisted search/status/repository filtering and elevates active or recently failed runs.
- [x] Pipeline rows expose operational context, duration, relative and exact time, full-row navigation, bounded-window feedback, and explicit refresh health.
- [x] Repository catalogue filtering, activity summaries, full-row navigation, progressive provider discovery, trust confirmation, and filtered-empty states are implemented.
- [x] Repository detail uses repository-scoped pipelines, prioritizes operational status, deep-links to the filtered cockpit, confirms manual runs, and contextualizes schedules.
- [x] Robine exposes embedded build provenance through a discreet footer and authenticated detail page, including a truthful development-build state.
- [x] Active navigation, responsive provenance access, shared page headings, nested breadcrumbs, focused administration work areas, sticky repository section navigation, normalized surfaces, and isolated destructive actions are implemented.
- [x] The authenticated product shell, shared headers, panels, states, and key screen copy express the documented Robine visual character in both light and dark themes.
- [x] The desktop navigation is implemented as a branded, contextual control column with tested active, provenance, and account states.

## Open questions

None blocking. MVP search is deliberately limited to the bounded visible log window; indexed full-log search is post-MVP. Semantic Tailwind design tokens and accessibility contracts are published in `docs/design-system.md`.

The required independent screen-reader session follows `docs/acceptance/accessibility.md`. Release evidence is schema-checked with `mix robine.verify_acceptance`; automated checks or a fixture generated by the implementation team cannot substitute for the unfamiliar human tester.

## Out of scope / future work

- Visual workflow authoring, annotations, organization dashboards, and custom themes.
