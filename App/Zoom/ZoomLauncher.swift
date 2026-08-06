//
//  ZoomLauncher.swift
//  Greenroom
//
//  Opens Zoom itself, or joins a known meeting via Zoom's zoommtg:// URL
//  scheme - the same mechanism calendar/browser "Join" links use. There's no
//  public way to set Zoom's active camera from here (see README) - that's a
//  one-time manual pick in Zoom's own Settings, which Zoom then remembers
//  for every future call on its own.
//
import Foundation
import AppKit

enum ZoomLauncher {

    static let bundleIdentifier = "us.zoom.xos"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Opens Zoom's own app - e.g. so the host can click "New Meeting" themselves.
    static func launchZoom() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(url)
        } else if let downloadURL = URL(string: "https://zoom.us/download") {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    /// Joins a known meeting by number (and optional passcode).
    static func join(meetingNumber: String, password: String) {
        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = "zoom.us"
        components.path = "/join"
        var items = [URLQueryItem(name: "confno", value: meetingNumber)]
        if !password.isEmpty {
            items.append(URLQueryItem(name: "pwd", value: password))
        }
        components.queryItems = items
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts a meeting AS HOST, straight in the native app - the same
    /// zoommtg:// mechanism as join, but with the host key (`zak`) the
    /// create-meeting API hands back. No browser hop, no "Open Zoom.app?"
    /// interstitial to get buried under other windows.
    static func startAsHost(meetingNumber: String, zak: String) {
        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = "zoom.us"
        components.path = "/start"
        components.queryItems = [
            URLQueryItem(name: "confno", value: meetingNumber),
            URLQueryItem(name: "zak", value: zak)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
