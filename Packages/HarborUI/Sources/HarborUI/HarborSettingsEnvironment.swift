// Licensed under GPL-3.0. See LICENSE.
//
//  HarborSettingsEnvironment.swift
//  HarborUI
//
//  The SwiftUI glue HarborSettings cannot carry: the settings service lives in a
//  Foundation-only package, so the environment key lives here, where the shared
//  settings bodies and both platforms' app targets all reach one key.
//

import HarborSettings
import SwiftUI

private struct HarborSettingsServiceKey: EnvironmentKey {
    @MainActor
    static var defaultValue: HarborSettingsService {
        if let service = EnvironmentValues.harborSettingsFallback { return service }
        let service = HarborSettingsService()
        EnvironmentValues.harborSettingsFallback = service
        return service
    }
}

extension EnvironmentValues {
    /// The service a view reads where none was injected. Any hosting view of its own (each
    /// sidebar page, AppKit-hosted controls) inherits nothing, so the default is reached often.
    /// Built on every read, it decoded every setting from UserDefaults dozens of times a space
    /// switch, and those views each held a copy the rest of the app never changed. The app sets
    /// its own service here at launch.
    @MainActor public static var harborSettingsFallback: HarborSettingsService?

    public var harborSettings: HarborSettingsService {
        get { self[HarborSettingsServiceKey.self] }
        set { self[HarborSettingsServiceKey.self] = newValue }
    }
}
