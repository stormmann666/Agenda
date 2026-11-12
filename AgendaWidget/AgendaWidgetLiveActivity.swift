import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@available(iOS 26.0, *)
struct AgendaWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<BlockAlarmMetadata>.self) { context in
            presentation(context).lockScreen
        } dynamicIsland: { context in
            presentation(context).dynamicIsland
        }
    }

    private func presentation(_ context: ActivityViewContext<AlarmAttributes<BlockAlarmMetadata>>) -> BlockCountdownPresentation {
        let title = context.attributes.metadata?.taskName ?? "Tarea de Agenda"
        guard case let .countdown(timer) = context.state.mode else {
            return BlockCountdownPresentation(title: title, interval: nil)
        }
        let interval = context.attributes.metadata?.interval
        let start = interval?.start ?? timer.startDate
        let end = interval?.end ?? max(start, timer.fireDate)
        return BlockCountdownPresentation(title: title, interval: start...end)
    }
}

@available(iOS 26.0, *)
struct AgendaBlockLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BlockActivityAttributes.self) { context in
            presentation(context).lockScreen
        } dynamicIsland: { context in
            presentation(context).dynamicIsland
        }
    }

    private func presentation(_ context: ActivityViewContext<BlockActivityAttributes>) -> BlockCountdownPresentation {
        if context.isStale {
            return BlockCountdownPresentation(title: "Bloque terminado", interval: nil)
        }
        let interval = context.state.interval
        return BlockCountdownPresentation(title: context.attributes.taskName, interval: interval.start...interval.end)
    }
}

private struct BlockCountdownPresentation {
    let title: String
    let interval: ClosedRange<Date>?

    var lockScreen: some View {
        HStack {
            Label(title, systemImage: "timer")
                .font(.headline)
                .lineLimit(2)
            Spacer()
            countdown
                .font(.title2.bold())
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding()
    }

    var dynamicIsland: DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: "timer")
            }
            DynamicIslandExpandedRegion(.trailing) {
                countdown.frame(minWidth: 72, alignment: .trailing)
            }
            DynamicIslandExpandedRegion(.bottom) {
                Text(title).lineLimit(1)
            }
        } compactLeading: {
            Image(systemName: "timer")
        } compactTrailing: {
            countdown.frame(width: 52)
        } minimal: {
            Image(systemName: "timer")
        }
    }

    private var countdown: Text {
        guard let interval else { return Text("0:00").monospacedDigit() }
        return Text(timerInterval: interval, countsDown: true,
                    showsHours: interval.upperBound.timeIntervalSince(interval.lowerBound) >= 3600)
            .monospacedDigit()
    }
}
