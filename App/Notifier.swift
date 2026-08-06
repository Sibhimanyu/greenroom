//
//  Notifier.swift
//  Greenroom
//
//  Local notification banners for events that happen while Greenroom is
//  buried behind the main app mid-session - recording started/saved,
//  mainly. Authorization is requested lazily on the first post (not at
//  launch, keeping first-run prompts where they belong: next to the
//  action that needs them); a denial silently disables banners, and the
//  menu bar indicator + status log still carry the signal.
//
import Foundation
import UserNotifications

enum Notifier {

    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { send() }
                }
            case .authorized, .provisional:
                send()
            default:
                break
            }
        }
    }
}
