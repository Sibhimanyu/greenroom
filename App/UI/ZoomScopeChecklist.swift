//
//  ZoomScopeChecklist.swift
//  Greenroom
//
//  The Server-to-Server app's scopes, the one place people copy them from:
//  the setup guide's Hosting app part. Each scope with what it is for, its
//  own Copy, and a "Missing" mark after a Check Zoom setup found it missing;
//  above them Copy scopes (all) and, when the check found any, Copy missing.
//  Zoom's scope search takes one name at a time, so the lists copy one per line.
//  (Settings -> Zoom had its own copy of this until 2026-11-26; it moved here
//  so there is one source.)
//
import AppKit
import SwiftUI

struct ZoomScopeChecklist: View {
    var scopes: [ZoomScopes.Scope] = ZoomScopes.all
    /// From the last Check Zoom setup; empty when it found none (or has not run).
    var missing: [String] = []

    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Scopes").font(.headline)
                Text("\(scopes.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if !missing.isEmpty {
                    Text("\(missing.count) missing")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Brand.netText)
                }
                Spacer(minLength: 8)
                if !missing.isEmpty {
                    copyButton(missing, key: "missing", title: "Copy missing",
                               help: "Copy the \(missing.count) missing scope\(missing.count == 1 ? "" : "s"), one per line")
                }
                copyButton(scopes.map(\.name), key: "all", title: "Copy scopes",
                           help: "Copy all \(scopes.count) scopes, one per line")
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(scopes) { scope in
                    row(scope)
                }
            }
        }
    }

    private func row(_ scope: ZoomScopes.Scope) -> some View {
        let isMissing = missing.contains(scope.name)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(scope.purpose).font(.callout.weight(.medium))
                    if isMissing {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.netText)
                    }
                }
                Text(scope.name).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            copyButton([scope.name], key: scope.name, title: "Copy", help: "Copy \(scope.name)")
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.text)
                .accessibilityLabel("Copy \(scope.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isMissing ? "Missing" : "")
    }

    private func copyButton(_ list: [String], key: String, title: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(list.joined(separator: "\n"), forType: .string)
            copied = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == key { copied = nil } }
        } label: {
            Label(copied == key ? "Copied" : title, systemImage: copied == key ? "checkmark" : "doc.on.doc")
        }
        .help(help)
    }
}
