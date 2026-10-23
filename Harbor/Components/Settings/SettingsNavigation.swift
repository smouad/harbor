// Licensed under GPL-3.0. See LICENSE.
//
//  SettingsNavigation.swift
//  Harbor
//

import Observation

/// Which settings tab the Settings window shows. Window navigation state, not a setting:
/// it never syncs, so it stays in the app rather than in HarborSettings.
@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var currentSettingsTab: SettingsTabs = .general
}
