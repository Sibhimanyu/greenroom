//
//  BrowserChromeDrag.swift
//  Greenroom
//
//  Which parts of the Greenroom Browser's top move the window, and what a
//  double-click there does. Pure: Foundation only.
//
//  Owner, 2026-11-26: "I am not able to drag around the Greenroom Browser
//  window by dragging the top part of it." Since ba2eff8 (2026-09-03) the tabs
//  live in the title bar of a full-size-content window, so SwiftUI content
//  (the tab strip's scroll view and background, the toolbar) covers the whole
//  title bar. Hosting views do not let a mouse-down move the window, so
//  `isMovableByWindowBackground` never had anything to work with.
//  `WindowDragArea` (BrowserWindow.swift) sits behind the empty parts and
//  hands the press to `NSWindow.performDrag(with:)`.
//
import Foundation

enum BrowserChromeDrag {

    enum Region: CaseIterable, Equatable {
        /// The tab strip around and after the tabs.
        case tabStripEmpty
        case tab, tabClose, newTabButton
        /// The toolbar's padding and the gaps between its controls, around the address field.
        case toolbarEmpty
        case toolbarButton, addressField, moreMenu
    }

    /// What a double-click on an empty part does, from System Settings > Desktop
    /// & Dock > "Double-click a window's title bar to".
    enum DoubleClick: Equatable { case zoom, minimise, nothing }

    static func dragsWindow(_ region: Region) -> Bool {
        switch region {
        case .tabStripEmpty, .toolbarEmpty: return true
        case .tab, .tabClose, .newTabButton, .toolbarButton, .addressField, .moreMenu: return false
        }
    }

    /// `actionSetting` is the global `AppleActionOnDoubleClick` ("Maximize",
    /// "Fill", "Minimize", "None"); `legacyMinimise` the older
    /// `AppleMiniaturizeOnDoubleClick`, read only when the newer one is unset.
    /// Fill has no public API, so it zooms.
    static func doubleClick(actionSetting: String?, legacyMinimise: Bool?) -> DoubleClick {
        switch actionSetting {
        case "Minimize": return .minimise
        case "None": return .nothing
        case "Maximize", "Fill": return .zoom
        default: return legacyMinimise == true ? .minimise : .zoom
        }
    }
}
