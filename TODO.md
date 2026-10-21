# gym_tracker

### Backlog

- [ ] `just e2e-web` fails after sign-up: `PhoneApp`'s `MaterialApp.builder` wraps the Navigator in `SelectableOnWeb`, and a `SelectionArea` above the Navigator has no `Overlay` ancestor, so a debug web build throws "No Overlay widget found" and never shows the routine list #bug
