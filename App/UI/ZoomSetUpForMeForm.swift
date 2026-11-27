//
//  ZoomSetUpForMeForm.swift
//  Greenroom
//
//  The one small form before Set up for me starts (docs/specs/zoom-setup-flow.md): the values Zoom asks
//  for on the hosting app's Information page (name, email, company), and, when Created apps already
//  lists an app of a type, "Use my existing app" or "Build a new one". Nothing is typed into Zoom
//  before Start. Plain values and closures, so it renders off screen.
//
import SwiftUI

struct ZoomSetUpForMeForm: View {
    @State var info: InfoValues
    /// The app types Created apps already lists.
    let existing: Set<ZoomApp>
    var onStart: (InfoValues, Set<ZoomApp>) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    @State private var buildNew: Set<ZoomApp> = []

    private var ready: Bool {
        !info.name.trimmingCharacters(in: .whitespaces).isEmpty && info.email.contains("@")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up for me").font(.title2.bold())
                Text("Greenroom fills in what Zoom asks for. Check these, then start. You can stop at any time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Your name", text: $info.name)
                row("Email", text: $info.email)
                row("Company", text: $info.company, prompt: info.name.isEmpty ? "Your name" : info.name)
            }
            Text("Zoom asks for these on the hosting app\u{2019}s Information page. The short description is \u{201C}\(info.description)\u{201D}")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !existing.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps you already have in Zoom").font(.headline)
                    ForEach([ZoomApp.meeting, .hosting].filter(existing.contains), id: \.self) { app in
                        Picker(app == .meeting ? "Meeting app" : "Hosting app", selection: choice(app)) {
                            Text("Use my existing app").tag(false)
                            Text("Build a new one").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start") { onStart(info, buildNew) }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.buttonFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                    .help(ready ? "Starts Set up for me" : "Add your name and email first")
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func row(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.greenroom)
        }
    }

    private func choice(_ app: ZoomApp) -> Binding<Bool> {
        Binding(get: { buildNew.contains(app) },
                set: { if $0 { buildNew.insert(app) } else { buildNew.remove(app) } })
    }
}
