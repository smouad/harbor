// Licensed under GPL-3.0. See LICENSE.
//
//  MemoryPressure.swift
//  HarboriOS
//
//  Jetsam does not warn twice. Two signals unload every page no window shows:
//  UIKit's memory warning, and a DispatchSource on the process's own pressure,
//  which fires before the warning does. Both are callbacks, not a poll.
//

import Foundation
import UIKit
import OSLog
import HarborWeb

@MainActor
final class MemoryPressureWatcher {
    private let logger = Logger(subsystem: "com.mouad.harbor", category: "Memory")
    private let source: DispatchSourceMemoryPressure
    private var observer: NSObjectProtocol?
    private weak var tabs: TabsController?

    init(tabs: TabsController) {
        self.tabs = tabs
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.unload("pressure") }
        }
        source.resume()

        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unload("warning") }
        }
    }

    deinit {
        source.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func unload(_ reason: String) {
        let before = tabs?.sessions.filter { !$0.isUnloaded }.count ?? 0
        tabs?.unloadAllHidden()
        let after = tabs?.sessions.filter { !$0.isUnloaded }.count ?? 0
        logger.notice("memory \(reason, privacy: .public): loaded pages \(before) -> \(after)")
    }

    #if DEBUG
    /// Neither signal can be raised from outside the process, so
    /// `-HarborSimulateMemoryWarning 1` posts the warning to check the unload path.
    /// The DispatchSource half still needs Simulator > Debug > Simulate Memory
    /// Warning, or real pressure on a device.
    static func simulateWarningIfRequested() {
        guard UserDefaults.standard.bool(forKey: "HarborSimulateMemoryWarning") else { return }
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    #endif
}
