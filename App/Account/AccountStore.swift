//
//  AccountStore.swift
//  Greenroom
//
//  PLACEHOLDER until the Thriveni API exists. Nothing here touches the
//  network: signIn() waits, then signs in as a made-up faculty member so the
//  screens and their states can be seen and judged. The real version will
//  open the system browser and finish with a loopback redirect plus PKCE, the
//  same pattern as App/YouTube/YouTubeAuth.swift, and take the profile and
//  scopes from Thriveni instead of from the preset below.
//
import Foundation
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    enum Scope: String, CaseIterable, Codable, Hashable {
        case youtubeUpload, thriveniPost
    }

    struct Profile: Equatable {
        var name: String
        var email: String
        var role: String
        var scopes: Set<Scope>

        var initials: String {
            let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
            return String(letters).uppercased()
        }
    }

    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(Profile)
    }

    /// Which mock permissions a sign-in grants. Debug UI picks one.
    enum ScopePreset: String, CaseIterable, Identifiable {
        case all, youtubeOnly, thriveniOnly, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Everything"
            case .youtubeOnly: return "YouTube only"
            case .thriveniOnly: return "Thriveni only"
            case .none: return "None"
            }
        }
        var scopes: Set<Scope> {
            switch self {
            case .all: return [.youtubeUpload, .thriveniPost]
            case .youtubeOnly: return [.youtubeUpload]
            case .thriveniOnly: return [.thriveniPost]
            case .none: return []
            }
        }
    }

    @Published private(set) var state: State = .signedOut
    @Published var preset: ScopePreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Self.presetKey)
            // Changing the preset while signed in changes what is granted.
            if case .signedIn(var profile) = state {
                profile.scopes = preset.scopes
                state = .signedIn(profile)
            }
        }
    }

    private static let signedInKey = "account.mock.signedIn"
    private static let presetKey = "account.mock.preset"
    private var signInTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        preset = ScopePreset(rawValue: defaults.string(forKey: Self.presetKey) ?? "") ?? .all
        if defaults.bool(forKey: Self.signedInKey) {
            state = .signedIn(Self.mockProfile(scopes: preset.scopes))
        }
    }

    var profile: Profile? {
        if case .signedIn(let profile) = state { return profile }
        return nil
    }

    func has(_ scope: Scope) -> Bool { profile?.scopes.contains(scope) ?? false }

    func signIn() {
        guard state == .signedOut else { return }
        state = .signingIn
        signInTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.state = .signedIn(Self.mockProfile(scopes: self.preset.scopes))
            UserDefaults.standard.set(true, forKey: Self.signedInKey)
        }
    }

    func cancel() {
        signInTask?.cancel()
        if state == .signingIn { state = .signedOut }
    }

    func signOut() {
        signInTask?.cancel()
        state = .signedOut
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
    }

    private static func mockProfile(scopes: Set<Scope>) -> Profile {
        Profile(name: "Priya Raman", email: "priya.raman@zohoschools.example", role: "Faculty", scopes: scopes)
    }
}
