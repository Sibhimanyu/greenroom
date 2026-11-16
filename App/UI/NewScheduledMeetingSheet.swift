//
//  NewScheduledMeetingSheet.swift
//  Greenroom
//
//  "New scheduled meeting…" from Home's Scheduled picker: a name, whether it
//  repeats weekly, and whether students wait in a waiting room. Create asks
//  Zoom; a refusal stays on the sheet in plain words. The weekly controls fold
//  away when "No fixed time" is chosen (DESIGN.md: dependent controls collapse).
//
import SwiftUI

struct NewScheduledMeetingSheet: View {
    enum Mode: Identifiable {
        case new
        case edit(Int64)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let id): return "edit-\(id)"
            }
        }
    }

    let mode: Mode
    init(mode: Mode = .new) { self.mode = mode }
    private var editID: Int64? { if case .edit(let id) = mode { return id } else { return nil } }

    @State private var loading = false
    @State private var loaded = false
    @State private var confirmingDelete = false

    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var request = NewMeetingRequest(name: "")
    @State private var creating = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private static let straightIn = "Come straight in"
    private static let waitForMe = "Wait for me to let them in"
    private static let repeats = ["No fixed time", "Weekly"]
    private static let durations = [30, 45, 60, 90, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editID == nil ? "New scheduled meeting" : "Edit meeting").font(.title3.weight(.semibold))
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading\u{2026}").foregroundStyle(.secondary) }
            }
            form
                .disabled(loading)
                .opacity(loading ? 0.5 : 1)
            footer
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { nameFocused = true }
        .task { await loadIfEditing() }
        .confirmationDialog("Delete \(request.trimmedName.isEmpty ? "this meeting" : request.trimmedName)?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Students\u{2019} link will stop working.")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.callout).foregroundStyle(.secondary)
                TextField("e.g. Maths 10B", text: $request.name)
                    .textFieldStyle(.greenroom)
                    .controlSize(.large)
                    .focused($nameFocused)
                    .onSubmit(create)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Repeats").font(.callout).foregroundStyle(.secondary)
                GreenroomSegmented("Repeats",
                                   selection: Binding(get: { request.weekly ? "Weekly" : "No fixed time" },
                                                      set: { v in fold { request.weekly = (v == "Weekly") } }),
                                   options: Self.repeats) { Text($0) }
                if request.weekly { weeklyControls.transition(.opacity.combined(with: .move(edge: .top))) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("When students join").font(.callout).foregroundStyle(.secondary)
                GreenroomSegmented("When students join",
                                   selection: Binding(get: { request.studentsJoinDirectly ? Self.straightIn : Self.waitForMe },
                                                      set: { request.studentsJoinDirectly = ($0 == Self.straightIn) }),
                                   options: [Self.straightIn, Self.waitForMe]) { Text($0) }
                Text(request.studentsJoinDirectly
                     ? "No waiting room. Anyone with the link joins at once."
                     : "Zoom\u{2019}s waiting room is on. You admit each person from Participants.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editID != nil {
                Text("The join link stays the same.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Brand.netText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if editID != nil {
                    Button("Delete meeting\u{2026}", role: .destructive) { confirmingDelete = true }
                        .disabled(creating || loading)
                }
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button(editID == nil ? "Create" : "Save", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || loading || (editID != nil && !loaded) || !request.isValid)
            }
        }
    }

    private func loadIfEditing() async {
        guard let id = editID, !loaded else { return }
        loading = true
        failure = nil
        do {
            request = try await coordinator.loadMeetingForEdit(id: id)
            loaded = true
        } catch {
            failure = error.localizedDescription
        }
        loading = false
    }

    private func delete() {
        guard let id = editID else { return }
        creating = true
        failure = nil
        let name = request.trimmedName
        Task {
            do {
                try await coordinator.deleteScheduledMeeting(id: id, name: name)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            creating = false
        }
    }

    private var weeklyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(NewMeetingRequest.weekdays, id: \.zoom) { day in
                    let on = request.days.contains(day.zoom)
                    Button {
                        if on { request.days.remove(day.zoom) } else { request.days.insert(day.zoom) }
                    } label: {
                        Text(day.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(Capsule().fill(on ? AnyShapeStyle(Brand.buttonFill) : AnyShapeStyle(.quinary)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 12) {
                // A menu like Duration's, in quarter hours: classes start on
                // the quarter, and the stepper field read as a different kind
                // of control (owner, 2026-11-16).
                Picker("Time", selection: startMinute) {
                    ForEach(Array(stride(from: 0, to: 24 * 60, by: 15)), id: \.self) {
                        Text(Self.clock($0)).tag($0)
                    }
                }
                .fixedSize()
                Picker("Duration", selection: $request.durationMinutes) {
                    ForEach(Self.durations, id: \.self) { Text("\($0) min").tag($0) }
                }
                .fixedSize()
            }
            Text("\(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier). Repeats for 50 weeks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var startMinute: Binding<Int> {
        Binding(get: { request.hour * 60 + request.minute },
                set: { request.hour = $0 / 60; request.minute = $0 % 60 })
    }

    private static func clock(_ minuteOfDay: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60,
                                         second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func fold(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.2)) { change() } }
    }

    private func create() {
        guard !creating, request.isValid else { return }
        creating = true
        failure = nil
        let spec = request
        Task {
            do {
                if let id = editID {
                    try await coordinator.updateScheduledMeeting(id: id, spec)
                } else {
                    try await coordinator.createScheduledMeeting(spec)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            creating = false
        }
    }
}
