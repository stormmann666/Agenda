//
//  AgendaWidgetBundle.swift
//  AgendaWidget
//
//  Created by Antonio Muñoz on 25/11/25.
//

import WidgetKit
import SwiftUI

@main
struct AgendaWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgendaWidget()
        AgendaWidgetControl()
        AgendaWidgetLiveActivity()
    }
}
