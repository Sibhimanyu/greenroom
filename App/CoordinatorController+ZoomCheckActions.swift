//
//  CoordinatorController+ZoomCheckActions.swift
//  Greenroom
//
//  What a Zoom check line's buttons do (which buttons a line gets is
//  `ZoomCheckActionRules`). Copying is the panel's own; everything that
//  leaves the panel comes here.
//
import AppKit

extension CoordinatorController {
    /// The client IDs the check buttons' tooltips name your own apps by.
    var zoomCheckIDs: ZoomCheckActionContext {
        ZoomCheckActionContext(sdkClientID: sdkClientID, s2sClientID: s2sClientID)
    }

    /// `kind` says which check to run again.
    func performZoomCheckAction(_ action: ZoomCheckAction, kind: ZoomCheckKind) {
        if let url = action.url {
            NSWorkspace.shared.open(url)
            return
        }
        switch action {
        case .showGuide(let spot):
            zoomSetupChecker.showingIn = nil
            zoomSignInChecker.showing = false
            zoomGuideSpot = spot
            presentOnboarding()
        case .signInAgain:
            zoomSignInChecker.showing = false
            signInWithZoom()
        case .useOwnApps:
            zoomSignInChecker.showing = false
            openZoomOwnApps()
        case .checkAgain:
            switch kind {
            case .ownApps: checkZoomSetup()
            case .signIn: checkZoomSignIn()
            }
        case .copyScope(let name):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        case .openScopesPage, .openAppCredentials, .openApp:
            break // opened above
        }
    }
}
