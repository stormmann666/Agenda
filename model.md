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
  - `startIndex: Int` – Slot index (15‑minute increments) since `dayStart`.
  - `duration: Int` – Number of slots (minimum 1).
  - `isCompleted: Bool` – New flag toggled from the check button inside each card.
- **Behavior**
  - When moving/resizing we only change `startIndex`/`duration` if the interval does not overlap with another task (`canPlace`).
  - Encoding provides a default (`false`) for `isCompleted` so older persisted data continues to load.

### `ScheduleDayLog`
- **Fields**
  - `id: UUID`
  - `date: Date` – Midnight anchor for the logged day.
  - `tasks: [TaskItem]` – Snapshot of every task (including `startIndex`, `duration` and `isCompleted`) at the time the day rolled over.
- **Creation**
  - On app launch we compare the last stored `wakeUpKey` with the current day. If the calendar day changed we archive the previous day’s tasks into a new `ScheduleDayLog` entry before clearing the schedule for the new day.

## Daily time window
- Each schedule “day” runs from **04:45** local time to **00:00** (midnight) of the following calendar day. The `wakeUpKey` stores the 04:45 anchor to detect day changes and ensure all 15‑minute blocks are generated within that window.

## Persistence Keys
- `agenda.categories.storage` → `[TaskCategory]`
- `agenda.tasks.storage` → `[TaskItem]` for the active day.
- `agenda.dayLogs.storage` → `[ScheduleDayLog]` historical archive.
- `agenda.wakeUpAnchor` → `Date` used as the start of the currently active day.

All collections are encoded via `JSONEncoder`/`JSONDecoder` and stored inside `UserDefaults.standard`.
