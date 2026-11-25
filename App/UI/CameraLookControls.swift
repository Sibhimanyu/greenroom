//
//  CameraLookControls.swift
//  Greenroom
//
//  The camera look, in the camera piece's inspector (Settings -> Layouts): background (Normal /
//  Blur / Image), background removal (Automatic / Green screen) and Mirror. One setting for every
//  layout (GLOSSARY.md, "Camera look"); the shape, size and spot are per layout and live beside it.
//  A folded group, so the inspector stays light. The Webcam tab these came from is gone (R11).
//
import ImageIO
import SwiftUI

/// The look's bindings, as plain values so the group renders off screen with sample data.
struct CameraLookModel {
    var background: Binding<CameraBackground>
    var backgroundImage: Binding<String>
    var removal: Binding<BackgroundRemoval>
    var mirror: Binding<Bool>
    var chooseImage: () -> Void
}

/// A folded group in the inspector: a chevron, a title, a note and, while closed, a one-line
/// summary. It opens and closes with `Collapse`, so Reduce Motion makes it instant.
struct InspectorFold<Content: View>: View {
    let title: String
    var note: String?
    var summary: String?
    var hint: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Collapse.animate { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !isOpen, let summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(hint)

            Collapsible(hidden: !isOpen) {
                content().padding(.top, 10)
            }
        }
    }
}

/// "Camera look", folded: its one-line summary and "Same in every layout" show closed. Dependent
/// rows fold away with the shape (the house rule), never greyed.
struct CameraLookGroup: View {
    let look: CameraLookModel
    let shape: WebcamShape
    @Binding var isOpen: Bool

    var body: some View {
        InspectorFold(title: "Camera look", note: CameraLookRules.sameInEveryLayout,
                      summary: CameraLookRules.summary(shape: shape, backgroundName: look.background.wrappedValue.rawValue,
                                                       removal: look.removal.wrappedValue, mirror: look.mirror.wrappedValue),
                      hint: "The background, removal and mirror are the same in every layout.",
                      isOpen: $isOpen) {
            VStack(alignment: .leading, spacing: 10) {
                Collapsible(hidden: !CameraLookRules.showsBackground(shape: shape)) {
                    CameraBackgroundControl(mode: look.background.animatedCollapse(), image: look.backgroundImage,
                                            choose: look.chooseImage)
                }
                Collapsible(hidden: !CameraLookRules.showsRemoval(shape: shape)) {
                    GreenroomSegmented("Background", selection: look.removal,
                                       options: [BackgroundRemoval.automatic, .greenScreen]) { option in
                        switch option {
                        case .automatic: Label("Remove automatically", systemImage: "wand.and.stars")
                        case .greenScreen: Label("Green screen", systemImage: "rectangle.fill")
                        }
                    }
                    .help("Automatic finds you in the camera and removes the rest. Green screen keys out a real green backdrop instead.")
                }
                Toggle(CameraLookRules.mirrorTitle, isOn: look.mirror)
                    .help(CameraLookRules.mirrorHelp)
            }
        }
    }
}

/// Normal, Blur or Image behind you; with Image, the pictures to pick from.
///
/// The picture row is its own `Collapsible`, so it folds away unless Image is
/// chosen (the house rule: dependent controls hide, they are not greyed).
struct CameraBackgroundControl: View {
    @Binding var mode: CameraBackground
    @Binding var image: String
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GreenroomSegmented("Background", selection: $mode.animatedCollapse(),
                               options: [CameraBackground.normal, .blur, .image]) { option in
                switch option {
                case .normal: Text("Normal")
                case .blur: Text("Blur")
                case .image: Text("Image")
                }
            }
            .help("Normal shows your room. Blur softens everything but you. Image puts a picture behind you.")

            Collapsible(hidden: mode != .image) {
                BackgroundImageRow(selection: $image, choose: choose)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
            }
        }
    }
}

/// The five bundled pictures, then the user's own, then Choose.
private struct BackgroundImageRow: View {
    @Binding var selection: String
    let choose: () -> Void

    private var hasCustom: Bool { CameraBackgroundLibrary.customFileURL != nil && CameraBackgroundLibrary.isCustom(selection) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CameraBackgroundPreset.allCases) { preset in
                BackgroundThumb(url: preset.url, title: preset.label,
                                selected: selection == preset.rawValue) {
                    selection = preset.rawValue
                }
            }
            if hasCustom {
                BackgroundThumb(url: CameraBackgroundLibrary.customFileURL, title: "Yours", selected: true) {}
            }
            Button(action: choose) {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.secondary)
                    Text("Choose\u{2026}")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                .frame(width: 64, height: 40)
            }
            .greenroomTile(role: .choice(selected: false))
            .help("Use a picture of your own")
            .accessibilityLabel("Choose your own background picture")
            Spacer(minLength: 0)
        }
    }
}

/// One background picture as a small tile, on the shared choice tile (ring and checkmark) when picked.
private struct BackgroundThumb: View {
    let url: URL?
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let url, let picture = Self.thumbnail(url) {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .greenroomTile(role: .choice(selected: selected))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Small copies, kept: a full-size JPEG is not decoded again on every
    /// redraw of the page. Keyed by file and modified time, so a new picture
    /// of the user's own replaces the old one.
    private static let cache = NSCache<NSString, NSImage>()
    private static func thumbnail(_ url: URL) -> NSImage? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}


