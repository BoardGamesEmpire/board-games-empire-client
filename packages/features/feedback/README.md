# feedback

User-initiated feedback compose flow (#107): the entry point for bug and
feature-request reports, terminating in the shared review & redaction
surface (`FeedbackReviewScreen`, #76) hosted by `app_shell`.

## Shape

- `FeedbackComposeFormModel` — owns the `reactive_forms` `FormGroup`:
  category (bug / feature request), severity (**required and enabled only
  for bug** — disabled controls are excluded from validity), message
  (required), optional title. Produces a `FeedbackComposeResult` on a
  valid submit.
- `FeedbackComposeForm` — the presentation over a host-owned model. The
  model lives with the host (`app_shell`'s `FeedbackFlowScreen`) so form
  state survives the compose → review → back-to-compose round trip.
- `FeedbackComposeResult` — the immutable hand-off value the host feeds
  into `FeedbackService.buildReport` (`message` maps to `userComment`;
  `errorMessage` stays null — user-initiated reports carry no error text).

There is deliberately **no bloc**: composing is synchronous state local to
the form; all async submission phases live in the review surface.

## Boundaries

This package never touches `FeedbackService`, routing, or the review
surface — `app_shell` owns that composition (the review surface lives
there and `app_shell` depends on features, never the reverse).

## i18n / a11y

All copy comes from `FeedbackLocalizations` (gitignored, regenerated —
`melos run generate`). Fields carry semantic labels; validation errors
render through the form decorations; the submit affordance is labelled
"Review report" because nothing is sent from this screen (#34 contract).
