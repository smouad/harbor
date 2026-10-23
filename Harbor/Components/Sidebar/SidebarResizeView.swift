// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarResizeView.swift
//  Harbor
//
//  Created by Maciek Bagiński on 30/07/2025.
//

import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

struct SidebarResizeView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.harborSettings) var harborSettings
    @State private var isResizing = false
    @State private var isHovering = false
    @State private var startingWidth: CGFloat = 0
    @State private var startingMouseX: CGFloat = 0
    @StateObject private var dragLockManager = DragLockManager.shared
    @State private var dragSessionID: String = UUID().uuidString
    @State private var hoverTask: Task<Void, Never>?

    private let minWidth = HarborDesign.Size.sidebarMin
    private let maxWidth: CGFloat = 520
    private let defaultWidth: CGFloat = HarborDesign.Size.sidebarDefault

    private var sitsOnRight: Bool {
        harborSettings.sidebarPosition == .right
    }

    private var hitAreaOffset: CGFloat {
        sitsOnRight ? 5 : -5
    }

    var body: some View {
        // No bar is drawn on the edge, as in Arc: hovering it shows only the resize cursor.
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 12)
                .padding(.vertical, 30)
                .offset(x: hitAreaOffset)
                .contentShape(.interaction, .rect)
                .onTapGesture(count: 2) {
                    guard windowState.isSidebarVisible else { return }
                    withAnimation(HarborDesign.Motion.spring) {
                        browserManager.updateSidebarWidth(defaultWidth, for: windowState)
                    }
                }
                .onHoverTracking { hovering in
                    guard windowState.isSidebarVisible else { return }

                    hoverTask?.cancel()

                    if hovering && !isResizing {
                        hoverTask = Task {
                            try? await Task.sleep(for: .seconds(0.1))
                            guard !Task.isCancelled else { return }
                            isHovering = true
                            NSCursor.resizeLeftRight.set()
                        }
                    } else {
                        isHovering = false
                        if !isResizing {
                            NSCursor.arrow.set()
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            guard windowState.isSidebarVisible else { return }

                            if !isResizing {
                                guard dragLockManager.startDrag(ownerID: dragSessionID) else {
                                    return
                                }

                                startingWidth = windowState.sidebarWidth
                                startingMouseX = value.startLocation.x
                                isResizing = true
                                NSCursor.resizeLeftRight.set()
                            }

                            let currentMouseX = value.location.x
                            let mouseMovement = sitsOnRight ? (startingMouseX - currentMouseX) : (currentMouseX - startingMouseX)
                            let newWidth = startingWidth + mouseMovement
                            let clampedWidth = max(minWidth, min(maxWidth, newWidth))

                            browserManager.updateSidebarWidth(clampedWidth, for: windowState)
                        }
                        .onEnded { _ in
                            isResizing = false
                            dragLockManager.endDrag(ownerID: dragSessionID)

                            if isHovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                )
        }
        .frame(width: 3)
    }
}
