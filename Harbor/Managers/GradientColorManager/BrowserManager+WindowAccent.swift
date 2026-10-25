// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+WindowAccent.swift
//  Harbor
//
//  The color a window paints its chrome with, read from the space the window shows.
//

import HarborDesign
import HarborSettings
import HarborTabsCore
import HarborWeb
import SwiftUI

extension BrowserManager {
    /// The accent of the space `window` shows, read from the space itself. A view that read it
    /// through `gradientColorManager` painted the space it had just left on a switch: that object
    /// is not what SwiftUI watches here, so the view drew before the new color was set and nothing
    /// asked it to draw again. The record is `@Observable`, so a body that reads it repaints in
    /// the same pass as the page. It also keeps a second window on its own space's color.
    func accentColor(for window: BrowserWindowState) -> Color {
        if window.isIncognito { return SpaceGradient.incognito.primaryColor }
        guard let spaceID = window.spaceID, let hex = tabs.space(spaceID)?.accentHex else {
            return gradientColorManager.accentColor
        }
        return SpaceGradient.accent(hex: hex).primaryColor
    }
}
