//
//  GeneralSettingsTab.swift
//  Greenroom
//
//  Settings -> General: things that are about Greenroom itself rather than a
//  meeting. For now, Privacy: anonymous usage analytics (moved from the
//  Layout tab; same defaults key, `analyticsEnabled`).
//
import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Anonymous usage analytics", isOn: $coordinator.analyticsEnabled)
                    .help("Counts and timings only. Never names, meeting IDs, addresses or chat.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
