// Licensed under GPL-3.0. See LICENSE.
//
//  AgentNotifier.swift
//  Harbor
//
//  Tells the person when an agent waits on them (an approval, a handoff) or a watched page
//  changed, with a system notification. Inside Harbor the Agent card shows the same thing.
//

import Foundation
import UserNotifications

@MainActor
enum AgentNotifier {
    static func approvalNeeded(_ request: AgentApprovals.Request) {
        post(id: request.id, title: "Approve agent action?", body: "\(request.taskTitle): \(request.action). \(request.reason).")
    }

    static func handoff(_ task: AgentTask, reason: String) {
        post(id: "handoff-\(task.id)", title: "Agent needs you", body: "\(task.title): \(reason)")
    }

    static func watchChanged(name: String, detail: String) {
        post(id: AgentID.make("w"), title: "\(name) changed", body: detail)
    }

    static func runFinished(title: String, ok: Bool, detail: String) {
        post(id: AgentID.make("r"), title: ok ? "\(title) finished" : "\(title) failed", body: detail)
    }

    static func withdraw(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private static func post(id: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
