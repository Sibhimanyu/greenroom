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

/// None and every template, one checked. Used inside a Menu.
struct LayoutChoiceItems: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Picker("Layout", selection: Binding<UUID?>(
            get: { coordinator.layoutLibrary.activeID },
            set: { coordinator.layoutLibrary.select($0) })) {
            Text("None").tag(UUID?.none)
            ForEach(coordinator.layoutLibrary.templates) { template in
                Text(template.name).tag(UUID?.some(template.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The Home line: small, secondary, and no louder than "Manual controls".
struct LayoutChoiceLine: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        let locked = coordinator.layoutChoiceLocked
        Menu {
            LayoutChoiceItems()
        } label: {
            Text("Layout: \(coordinator.layoutChoiceName)")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(locked)
        .help(locked
              ? "A class runs the layout it started with. Pick the next one after it ends, or use Settings \u{2192} Layout \u{2192} Apply now."
              : "Where Start puts the meeting, the chat and your apps. Edit layouts in Settings \u{2192} Layout.")
        .accessibilityLabel("Layout")
        .accessibilityValue(coordinator.layoutChoiceName)
    }
}
