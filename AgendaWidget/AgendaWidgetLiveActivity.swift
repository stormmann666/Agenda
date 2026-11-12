import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@available(iOS 26.0, *)
struct AgendaWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<BlockAlarmMetadata>.self) { context in
            HStack {
                Label(taskName(context), systemImage: "timer")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                countdown(context)
                    .font(.title2.bold())
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(taskName(context))
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                countdown(context)
                    .frame(width: 52)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    private func taskName(_ context: ActivityViewContext<AlarmAttributes<BlockAlarmMetadata>>) -> String {
        context.attributes.metadata?.taskName ?? "Tarea de Agenda"
    }

    private func countdown(_ context: ActivityViewContext<AlarmAttributes<BlockAlarmMetadata>>) -> Text {
        if case let .countdown(timer) = context.state.mode {
            let interval = context.attributes.metadata?.interval
            let start = interval?.start ?? timer.startDate
            let end = interval?.end ?? max(start, timer.fireDate)
            return Text(timerInterval: start...end,
                        countsDown: true,
                        showsHours: end.timeIntervalSince(start) >= 3600)
                .monospacedDigit()
        }
        return Text("0:00").monospacedDigit()
    }
}
