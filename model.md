# Agenda Data Model

## Entities

### `TaskCategory`
- **Fields**
  - `id: UUID` – Stable identifier stored with each task.
  - `name: String` – Display name edited in “Tipos de tarea”.
  - `colorHex: String` – Hex representation persisted in `UserDefaults`.
- **Notes**: Categories are encoded/decoded as JSON arrays and shared across every day.

### `TaskItem`
- **Fields**
  - `id: UUID`
  - `categoryID: UUID` – Links to `TaskCategory`.
  - `startIndex: Int` – Slot index (5‑minute increments) since `dayStart`.
  - `duration: Int` – Number of slots (minimum 1).
  - `isCompleted: Bool` – New flag toggled from the check button inside each card.
  - `focusID: UUID?` – Optional link to a `FocusItem` currently embedded in the box.
  - `isFocusIndeterminate: Bool` – Indicates the box is marked as focused but without a concrete `FocusItem`.
- **Behavior**
  - When moving/resizing we only change `startIndex`/`duration` if the interval does not overlap with another task (`canPlace`).
  - Encoding provides a default (`false`) for `isCompleted` so older persisted data continues to load.

### `FocusItem`
- **Fields**
  - `id: UUID`
  - `name: String`
  - `assignedTaskID: UUID?` – Identifies the task currently hosting the focus (if any).
  - `expectedMinutes: Int?` – Estimated effort (in minutes). `nil` means indeterminado.
- **Behavior**
  - Focuses live independently from boxes. They can exist unassigned (waiting to be placed) or associated with a single task.
  - Assigning/detaching a focus updates both the task (`focusID`) and the focus (`assignedTaskID`) so the relationship stays in sync.

### `ScheduleDayLog`
- **Fields**
  - `id: UUID`
  - `date: Date` – Midnight anchor for the logged day.
  - `tasks: [TaskItem]` – Snapshot of every task (including `startIndex`, `duration` and `isCompleted`) at the time the day rolled over.
- **Creation**
  - On app launch we compare the last stored `wakeUpKey` with the current day. If the calendar day changed we archive the previous day’s tasks into a new `ScheduleDayLog` entry before clearing the schedule for the new day.

## Daily time window
- Each schedule “day” runs from **04:45** local time to **00:00** (midnight) of the following calendar day. The `wakeUpKey` stores the 04:45 anchor to detect day changes and ensure all 5‑minute blocks are generated within that window.

## Persistence Keys
- `agenda.categories.storage` → `[TaskCategory]`
- `agenda.tasks.storage` → `[TaskItem]` for the active day.
- `agenda.dayLogs.storage` → `[ScheduleDayLog]` historical archive.
- `agenda.wakeUpAnchor` → `Date` used as the start of the currently active day.
- `agenda.focuses.storage` → `[FocusItem]` independent focus backlog.

All collections are encoded via `JSONEncoder`/`JSONDecoder` and stored inside `UserDefaults.standard`.

## Task mutations
- **Placement rules**: `canPlace(start:duration:ignoring:)` blocks overlaps by ensuring the new interval stays within `totalBlocks` and does not intersect any other task’s range.
- **Movement helpers**:
  - `move(task:by:)` / `move(task:to:)` change `startIndex` directly when the destination is free.
  - `shiftGroup(startingFrom:by:)` shifts the active task and every later task as a block (used when dragging down into occupied territory).
  - `adjustTaskPosition(for:by:)` is the high-level entry point invoked by the UI; it tries a free move first and automatically falls back to `shiftGroup` only if necessary.
- **Duration helpers**:
  - `resize(task:newDuration:)` resizes a task provided the enlarged interval is still free.
  - `adjustTaskDuration(for:by:)` clamps the requested delta between 1 block and the remaining space of the day, then delegates to `resize`.
  - `adjustTaskEndTime(for:to:)` lets callers specify the exact end `Date` (redondeada al siguiente bloque de 5 minutos y sin sobrepasar la duración actual).
  - `finishTask(_:at:)` es un atajo que pasa la hora actual a `adjustTaskEndTime`.
- **Focus helpers**:
  - `addFocus`, `updateFocus`, `deleteFocus` manage the standalone focus backlog.
  - `assignFocus(_:to:)` embeds or removes a focus from a task, keeping both sides synchronized and clearing `isFocusIndeterminate`.
  - `clearFocus(for:)` removes any associated focus from a task and frees the focus for later use.
  - `setTaskFocusIndeterminate(_:isIndeterminate:)` toggles the “focused pero indefinido” state y, cuando pasa a indeterminado, libera al focus para que otros boxes puedan tomarlo.
  - Focus persistence stays consistent through `mutateTasks` calling `cleanupFocusAssignments()` so any dangling assignments are automatically cleared when tasks disappear.
- **Persistence**: Any mutation routes through `mutateTasks`/`mutateCategories`, which copy the arrays, apply the change, publish via `@Published` and save the updated payload back to `UserDefaults`.

## Testing
- `AgendaTests/ScheduleViewModelTests.swift` covers:
  - `adjustTaskDuration` clamping to at least one block and not exceeding the day.
  - `adjustTaskPosition` moving freely or shifting downstream groups when needed.
  - `finishTask` rounding the task’s end time to the current 5‑minute slot.
  - `adjustTaskEndTime` honoring explicit end hours and the focus assignment lifecycle (`testFocusLifecycleAssignAndDetach`, `testFocusIndeterminateState`).
- Run them from Xcode (Product → Test) or via CLI:
  ```
  xcodebuild test -scheme Agenda -destination 'platform=iOS Simulator,name=iPhone 15'
  ```
