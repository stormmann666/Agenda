import SwiftUI
import WidgetKit

@main
struct AgendaWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 26.0, *) {
            AgendaBlockLiveActivity()
            AgendaWidgetLiveActivity()
        }
    }
}
