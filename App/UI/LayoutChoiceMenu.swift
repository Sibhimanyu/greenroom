//
//  LayoutChoiceMenu.swift
//  Greenroom
//
//  The two quiet places to pick the Start layout without opening Settings: a
//  "Layout: <name>" menu line under Start on Home, and a Layout submenu in the
//  menu bar. Both list None and the templates, and both set the same thing
//  Settings -> Layout does (`layoutLibrary.activeID`).
//
//  Disabled while a class is live. A class runs the layout it started with
//  (`sessionTemplate`), so a pick made mid-class would change nothing on screen
//  and only surprise the next Start. Settings -> Layout has "Apply now" for the
//  one case where re-tiling a live class is wanted.
//
import SwiftUI

/// Every layout, one checked (there is no None: Leave my windows alone is the "move nothing" one). Used inside a Menu.
struct LayoutChoiceItems: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Picker("Layout", selection: Binding<UUID?>(
            get: { coordinator.layoutLibrary.activeID },
            set: { coordinator.layoutLibrary.select($0) })) {
            ForEach(coordinator.layoutLibrary.templates) { template in
                Text(template.name).tag(UUID?.some(template.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
