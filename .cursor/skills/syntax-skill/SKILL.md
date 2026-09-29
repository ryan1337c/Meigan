---

name: syntax-skill
description: Applies conventional SwiftUI syntax, structure, naming, documentation, and formatting.
disable-model-invocation: true
------------------------------

# SwiftUI Organizer

Apply these conventions when organizing or modifying Swift/SwiftUI code.

## Comments

* Comment **why**, not what. Avoid comments that restate obvious code.
* Use `// MARK: - Section` for meaningful sections only.
* Use `///` for non-obvious public APIs, parameters, return values, and behavior.
* Use `TODO:` for planned work and `FIXME:` for known issues.
* Remove or update stale comments.
* Prefer clear naming and structure over explanatory comments.

## View Structure

Prefer this order:

1. `// MARK: - Properties`
2. `// MARK: - Initialization` when needed
3. `// MARK: - Body`
4. `// MARK: - Views`
5. `// MARK: - Actions`
6. `// MARK: - Helpers`

Keep small views simple. Extract large `body` sections into meaningful computed views or separate `View` types.

## Swift Conventions

* Types: `UpperCamelCase`.
* Properties/functions: `lowerCamelCase`.
* Booleans: `is...`, `has...`, `can...`, `should...`.
* Default implementation details to `private`.
* Prefer descriptive names over comments.
* Avoid magic numbers/strings when they represent meaningful constants.
* Keep imports minimal.
* Preserve existing project architecture and formatting tools.

## State

Use property wrappers according to ownership:

* `@State`: view-owned local state.
* `@Binding`: mutable state owned by another view.
* `@Environment`: environment-provided dependencies/values.
* Use `@Observable`/`@Bindable` when the project uses Swift Observation.
* Use `@StateObject`/`@ObservedObject` only where the project's `ObservableObject` architecture requires them.
* Avoid storing values that can be derived.

## SwiftUI

* Prefer current APIs compatible with the deployment target.
* Modifier order should generally progress from content → layout → appearance → interaction → accessibility → lifecycle.
* Never reorder modifiers when doing so changes behavior.
* Prefer semantic controls (`Button`, `Toggle`, etc.) over gesture-based interaction when appropriate.
* Keep business/data logic out of views when the architecture provides another layer for it.
* Use `.task` for view-lifecycle async work; respect cancellation.
* Handle errors intentionally; don't silently discard them without a reason.

## Accessibility

* Provide meaningful accessibility labels for icon-only controls.
* Prefer semantic SwiftUI controls.
* Avoid unnecessary fixed font sizes.
* Support Dynamic Type and system accessibility behavior.

## Previews

Use `#Preview` for meaningful views when previews are part of the project. Use local/preview data; never require production networking or authentication.

## Modification Rules

When editing existing code:

* Preserve established architecture and conventions.
* Make the smallest necessary change.
* Avoid unrelated refactoring.
* Keep conventions consistent within the file.
* Update/remove comments affected by code changes.

## Principle

**Readable code first; comments explain non-obvious intent.**
