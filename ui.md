# Agenda UI Notes

## Timeline interactions
- Cada bloque visual corresponde a un `TaskItem` dentro de un `LazyVStack` scrolleable. Gestos disponibles: toque simple (selección), doble toque (abrir editor de categoría), arrastre vertical (mover), pulsación larga + arrastre (redimensionar) y un `contextMenu`.
- El menú contextual ofrece “Terminar Box”, acción que acorta la tarea para que termine en el siguiente múltiplo de 15 minutos respecto al momento actual. Esta acción sólo modifica `duration`; los demás tasks mantienen su `startIndex` para que el hueco quede libre.
- Tras terminar un box se fuerza un nuevo `id` en el `LazyVStack` para que SwiftUI regenere toda la estructura y muestre inmediatamente la nueva altura, los minutos restantes y los espacios vacíos disponibles.
