//
//  AccountSettingsTab.swift
//  Greenroom
//
//  Settings -> Account: the Thriveni sign-in (dummy for now, see AccountStore).
//  Also home to the account chip's destination and the Post to Thriveni sheet.
//
import SwiftUI

struct AccountSettingsTab: View {
    @ObservedObject private var account = AccountStore.shared

    var body: some View {
        Form {
            switch account.state {
            case .signedOut:
                Section("Account") {
                    Text("Sign in with Thriveni to upload recordings to the Zoho Schools YouTube channel and post them to your assignments.")
                        .foregroundStyle(.secondary)
                    Button("Sign in with Thriveni") { account.signIn() }
                        .buttonStyle(.borderedProminent)
                }
            case .signingIn:
                Section("Account") {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser\u{2026}")
                        Spacer()
                        Button("Cancel") { account.cancel() }
                    }
                }
            case .signedIn(let profile):
                Section("Account") {
                    LabeledContent("Name", value: profile.name)
                    LabeledContent("Email", value: profile.email)
                    LabeledContent("Role", value: profile.role)
                    Button("Sign out") { account.signOut() }
                }
                Section("Access") {
                    accessRow("Upload to the Zoho Schools YouTube channel", granted: profile.scopes.contains(.youtubeUpload))
                    accessRow("Post links to Thriveni assignments", granted: profile.scopes.contains(.thriveniPost))
                }
            }
            #if DEBUG
            Section("Mock access (debug)") {
                Picker("Mock access", selection: $account.preset) {
                    ForEach(AccountStore.ScopePreset.allCases) { Text($0.title).tag($0) }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func accessRow(_ title: String, granted: Bool) -> some View {
        LabeledContent {
            if granted {
                StatusBadge(text: "Granted", tone: .good)
            } else {
                Text("Ask your Thriveni admin for access")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
        }
    }
}

// MARK: - Sidebar chip

struct AccountChip: View {
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .showSettingsTab, object: "account")
            }
        } label: {
            HStack(spacing: 8) {
                avatar
                Text(label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(account.profile == nil ? "Sign in with Thriveni." : "Account settings.")
    }

    private var label: String { account.profile?.name ?? "Sign in" }

    @ViewBuilder private var avatar: some View {
        if let profile = account.profile {
            Text(profile.initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Brand.green, in: Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - Post to Thriveni

struct PostToThriveniButton: View {
    @ObservedObject private var account = AccountStore.shared
    let link: String
    @State private var showing = false

    private var allowed: Bool { account.has(.thriveniPost) }

    var body: some View {
        Button("Post to Thriveni") { showing = true }
            .disabled(!allowed)
            .help(allowed ? "Posts this link to one of your Thriveni assignments."
                          : (account.profile == nil
                             ? "Sign in with Thriveni in Settings \u{2192} Account first."
                             : "Your Thriveni account can\u{2019}t post to assignments. Ask your Thriveni admin for access."))
            .sheet(isPresented: $showing) { PostToThriveniSheet(link: link) }
    }
}

struct PostToThriveniSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var link: String
    @State private var assignment = ThriveniMock.assignments[0]
    @State private var note = ""
    @State private var posting = false
    @State private var postedTo: ThriveniMock.Assignment?

    init(link: String) {
        _link = State(initialValue: link.isEmpty ? "https://youtu.be/XXXXXXXX" : link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Post to Thriveni").font(.title3.weight(.semibold))
            if let postedTo {
                StatusBadge(text: "Posted to \(postedTo.label)", tone: .good)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Picker("Assignment", selection: $assignment) {
                    ForEach(ThriveniMock.assignments) { item in
                        Text("\(item.label) (due \(item.due.formatted(date: .abbreviated, time: .omitted)))").tag(item)
                    }
                }
                TextField("YouTube link", text: $link)
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Spacer()
                    if posting { ProgressView().controlSize(.small) }
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Post") { post() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(posting || link.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func post() {
        posting = true
        let target = assignment
        Task {
            try? await ThriveniMock.post(link: link, to: target, note: note)
            posting = false
            postedTo = target
        }
    }
}
