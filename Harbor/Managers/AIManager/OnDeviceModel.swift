// Licensed under GPL-3.0. See LICENSE.
//
//  OnDeviceModel.swift
//  Harbor
//
//  The one system language model (Apple Intelligence) the app uses: the tab organizer, the
//  on-device chat and the agent's critic, healing and extract.
//
//  One instance on purpose. Each SystemLanguageModel keeps its `availability` current on a
//  background task that holds FoundationModels' lock while it tells observers, and so waits for
//  SwiftUI's graph lock; a view reading `isAvailable` during a graph update (HarborCommands) takes
//  the two in the other order. A second instance made mid-session, while agent calls kept the
//  graph busy, deadlocked the app that way (main thread in `TabOrganizationModel.isAvailable`, the
//  model's task in `ObservationCenter.invalidate`). Every new instance starts that task again.
//

import FoundationModels

enum OnDeviceModel {
    static let shared = SystemLanguageModel(guardrails: .permissiveContentTransformations)
}
