// Licensed under GPL-3.0. See LICENSE.
//
//  ShortcutConflictToast.swift
//  Harbor
//
//  Created by AI Assistant on 2025.
//
//  Toast notification shown when a keyboard shortcut conflicts between
//  Harbor and a website. Informs users they can press again for Harbor action.
//

import SwiftUI
import HarborDesign

// MARK: - Shortcut Conflict Toast View

public struct ShortcutConflictToast: View {
    /// The shortcut as the user typed it, e.g. "⌘K".
    let shortcut: String
    let websiteName: String
    let harborActionName: String
    
    public init(
        shortcut: String,
        websiteName: String,
        harborActionName: String
    ) {
        self.shortcut = shortcut
        self.websiteName = websiteName
        self.harborActionName = harborActionName
    }

    public var body: some View {
        ToastView {
            HStack(spacing: 10) {
                // Keyboard icon
                Image(systemName: "keyboard")
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .padding(5)
                    .background(HarborDesign.Surface.fill)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
                    .overlay {
                        HarborDesign.Radius.shape(HarborDesign.Radius.md)
                            .stroke(HarborDesign.Surface.hairline, lineWidth: 1)
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    // Title: shortcut key used by website
                    HStack(spacing: 4) {
                        Text(shortcut)
                            .font(HarborDesign.Font.secondary)
                            .foregroundStyle(.primary)
                        Text("used by")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                        Text(websiteName)
                            .font(HarborDesign.Font.secondary)
                            .foregroundStyle(.primary)
                    }
                    
                    // Subtitle: press again for Harbor
                    HStack(spacing: 4) {
                        Text("Press again for")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                        Text(harborActionName)
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .transition(.toast)
    }
}

// MARK: - Preview

#Preview {
    ShortcutConflictToast(
        shortcut: "⌘K",
        websiteName: "Figma",
        harborActionName: "Command Palette"
    )
    .padding()
    .background(Color.gray.opacity(0.3))
}