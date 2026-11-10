//
//  ZoomWindowManager.swift
//  Greenroom
//
//  The Accessibility grant, in one place. Greenroom tiles the main-pane app
//  (Chrome, Keynote and so on) through the Accessibility API, and the chat
//  column reads the same grant. The meeting itself runs in Greenroom's own
//  Zoom client, whose window Greenroom parks in-process, so nothing here
//  looks for or moves the separate Zoom app any more.
//
import AppKit
import ApplicationServices

enum ZoomWindowManager {

    static var hasAccessibilityPermission: Bool { AppWindowManager.hasAccessibilityPermission }

    static func promptForAccessibilityPermission() {
        AppWindowManager.promptForAccessibilityPermission()
    }
}
