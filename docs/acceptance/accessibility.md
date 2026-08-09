# Manual screen-reader acceptance protocol

## Purpose

Verify the automated semantic checks with a real assistive-technology session conducted by a developer unfamiliar with Robine's implementation.

## Preconditions

- The tester has not contributed to Robine and has not been coached on its DOM or implementation.
- Use a current screen reader and supported browser combination, such as NVDA with Firefox/Chrome or VoiceOver with Safari.
- Seed realistic repository, running-pipeline, failed-job, and retryable-job data without changing the UI for the session.
- The facilitator may state the user goal but must not tell the tester which control, landmark, or shortcut to use.

## Required journeys

For every journey, the tester uses the keyboard only and confirms that focus order is logical, controls and status changes are announced understandably, recovery guidance is discoverable, and no focus trap occurs:

1. Complete first-run setup.
2. Sign in.
3. Connect or select a trusted repository.
4. Inspect a running pipeline and identify current activity.
5. Diagnose the first failing step and find the local reproduction command.
6. Cancel an active pipeline and retry an eligible failed job through the confirmations.

Record each result in a copy of `accessibility.template.json`. A journey with a blocking issue cannot pass. Major or critical findings must be fixed and retested; only minor or moderate findings may be explicitly accepted with a durable issue/decision reference. Run `mix robine.verify_acceptance` with both external evidence files and the retained release `SHA256SUMS` manifest after the retest.
