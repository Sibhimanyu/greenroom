//
//  ModelAssets.swift
//  Greenroom
//
//  Whether the speech model for the chosen language is on this Mac, and the
//  one-time download when it is not.
//
//  The model comes from Apple through the system's asset service - the same
//  mechanism Dictation uses - not from Greenroom's site. It is fetched when
//  the teacher turns Cues on in Settings, with a progress bar, and never
//  during a class: a Start that finds no model logs why and carries on
//  without Cues rather than pulling a download into the first minute of
//  a lesson.
//
import Foundation
import Speech

@available(macOS 26.0, *)
@MainActor
final class ModelAssets: ObservableObject {

    /// One instance: Settings and Onboarding both show it, and the coordinator
    /// reads it at Start.
    static let shared = ModelAssets()

    enum Status: Equatable {
        case unknown
        /// The language is not one the transcriber can do at all.
        case unsupported
        case notDownloaded
        case downloading(Double)
        case installed
        case failed(String)

        var isInstalled: Bool { self == .installed }
        var label: String {
            switch self {
            case .unknown: return "Checking\u{2026}"
            case .unsupported: return "This language is not supported"
            case .notDownloaded: return "Not downloaded"
            case .downloading(let fraction): return "Downloading\u{2026} \(Int((fraction * 100).rounded()))%"
            case .installed: return "Installed"
            case .failed(let why): return "Download failed: \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var resolvedLocale: Locale = Locale(identifier: "en_US")
    private var progressObservation: NSKeyValueObservation?

    /// What the transcriber can do, for the language picker. Sorted by name.
    static func supportedLocales() async -> [Locale] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales.sorted { Self.displayName($0) < Self.displayName($1) }
    }

    static func displayName(_ locale: Locale) -> String {
        let language = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier
        let region = locale.region.flatMap { locale.localizedString(forRegionCode: $0.identifier) } ?? ""
        return region.isEmpty ? language : "\(language) \u{00B7} \(region)"
    }

    func refresh(preferredLocale identifier: String) async {
        let locale = await Transcriber.resolvedLocale(preferred: identifier)
        resolvedLocale = locale
        let transcriber = Transcriber.makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: status = .installed
        case .downloading: if case .downloading = status {} else { status = .downloading(0) }
        case .supported: status = .notDownloaded
        case .unsupported: status = .unsupported
        @unknown default: status = .notDownloaded
        }
    }

    /// Reserves the locale (so the system keeps its assets) and installs
    /// whatever the transcriber still needs. Progress arrives on `status`.
    func download(preferredLocale identifier: String) async {
        let locale = await Transcriber.resolvedLocale(preferred: identifier)
        resolvedLocale = locale
        let transcriber = Transcriber.makeTranscriber(locale: locale)
        status = .downloading(0)
        do {
            // Reservations are capped by the system; a failed reservation is
            // not fatal, the assets can still install.
            _ = try? await AssetInventory.reserve(locale: locale)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                status = .installed
                return
            }
            progressObservation = request.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(fraction)
                }
            }
            try await request.downloadAndInstall()
            progressObservation = nil
            await refresh(preferredLocale: identifier)
            if status != .installed { status = .installed }
        } catch {
            progressObservation = nil
            status = .failed(error.localizedDescription)
        }
    }
}
