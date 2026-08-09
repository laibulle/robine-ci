# WEB-001 — Pipeline experience

## Status

- **State:** Draft
- **Owner:** Web
- **Target:** MVP
- **Last updated:** 2026-08-09

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

### UX requirements

- **UX-1:** Core pages MUST meet WCAG 2.2 AA for keyboard navigation, focus, contrast, labels, and status not conveyed by color alone.
- **UX-2:** Every empty, loading, disconnected, degraded, and error state MUST be explicitly designed.
- **UX-3:** LiveView reconnects MUST restore the current view and request only missing log segments.
- **UX-4:** Destructive or costly actions MUST use clear confirmations and prevent duplicate submission.
- **UX-5:** The interface MUST be responsive down to a practical phone viewport, while desktop remains the primary log-analysis target.

### Operational requirements

- **OR-1:** Initial job pages MUST not load the full log into server or browser memory.
- **OR-2:** Live log delivery MUST use sequence cursors and support reconnection without duplication.
- **OR-3:** Server-rendered pages SHOULD expose meaningful content before LiveView connects.
- **OR-4:** Tailwind usage MUST follow a documented design-token layer rather than ad hoc colors and spacing.

## Proposed design

The UI follows the semantic token and component contracts in `docs/design-system.md`. Light and dark themes implement the palette, while product templates consume intent-level surface, content, action, and status semantics. All interactive controls share a visible keyboard focus treatment, status text never depends on color alone, and operating-system reduced-motion preferences override decorative transitions.

The primary navigation contains Repositories, Pipelines, and Administration. Repository pages show integration health, workflows, recent runs, secrets, and settings. Pipeline pages use a compact graph on desktop and an ordered dependency list on small screens.

The MVP graph representation is an accessible dependency-ordered list: every job names its prerequisites, durable status, latest runner phase, elapsed duration, and terminal reason. Pipeline metadata persists the source trigger, initiating actor, exact commit, execution start, and terminal finish. Runner-loss and system-failure reasons are elevated as infrastructure failures and are visually and textually distinct from repository command failures and timeouts. This list is the canonical accessible graph; a decorative node-edge rendering may be layered on later without replacing it.

The log viewer stores neither all output in a LiveView socket nor all rendered nodes in the browser. It requests bounded segments by sequence cursor, appends live events, and offers server-side search. ANSI output is sanitized and rendered through a restricted parser. Raw log download is available subject to authorization and retention.

Every persisted log segment carries an explicit runner phase (`image_acquisition`, `execution`, or `cleanup`) in addition to its step position. The job page renders phase sections containing expandable step groups; both levels have stable anchors, and search preserves the phase context of every match.

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

- [ ] A user can complete all MVP administration through the UI.
- [ ] A running job updates without manual refresh and reconnects without duplicate log lines.
- [ ] A 100 MB test log can be navigated without loading 100 MB into a LiveView process or browser DOM.
- [ ] A failed step is apparent from the pipeline page and directly linkable.
- [ ] All core journeys pass automated keyboard and accessibility checks, plus a manual screen-reader smoke test.
- [ ] Retry clearly handles present and expired dependency artifacts.

## Open questions

- Define log search indexing and raw download behavior for the MVP.
- Create the initial visual design tokens before feature implementation.

## Out of scope / future work

- Visual workflow authoring, annotations, organization dashboards, and custom themes.
