// Licensed under GPL-3.0. See LICENSE.
//
//  HarborDragSourceView.swift
//  Harbor
//

import SwiftUI
import AppKit

// MARK: - Drag Source Coordinator (NSDraggingSource)

@MainActor
final class HarborDragSourceCoordinator: NSObject, NSDraggingSource {
    var item: HarborDragItem
    var icon: Image?
    var zoneID: DropZoneID
    let manager: HarborDragSessionManager

    init(item: HarborDragItem, icon: Image?, zoneID: DropZoneID, manager: HarborDragSessionManager) {
        self.item = item
        self.icon = icon
        self.zoneID = zoneID
        self.manager = manager
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .move : .copy
    }

    // NSDraggingSource is declared NS_SWIFT_UI_ACTOR, so these run on the main actor
    // statically. Marking them nonisolated and hopping back with assumeIsolated added a
    // dynamic executor check that segfaults after any ObjC exception has unwound a
    // main-actor task (see ExternalMiniWindowManager.items(for:) for the same fix).
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        manager.updateCursorScreenPosition(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] {
            manager.cancelDrag()
        }
    }
}

// MARK: - DragSourceNSView

final class HarborDragSourceNSView: NSView {
    var coordinator: HarborDragSourceCoordinator?
    private(set) var registrationId: UUID?

    func registerWithManager() {
        guard let coordinator = coordinator else { return }
        let id = UUID()
        registrationId = id
        coordinator.manager.registerDragSource(self, id: id)
    }

    func unregisterFromManager() {
        guard let id = registrationId, let coordinator = coordinator else { return }
        coordinator.manager.unregisterDragSource(id: id)
        registrationId = nil
    }

    func initiateDrag(with event: NSEvent) {
        guard let coordinator = coordinator else { return }

        // Capture screen position from the event for preview window positioning
        let screenPoint: NSPoint
        if let window = self.window {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }

        coordinator.manager.beginDrag(
            item: coordinator.item,
            icon: coordinator.icon,
            from: coordinator.zoneID,
            cursorScreenPoint: screenPoint
        )

        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(coordinator.item) {
            pasteboardItem.setData(data, forType: .harborTabItem)
        }
        pasteboardItem.setString(coordinator.item.tabId.uuidString, forType: .string)

        let transparentImage = NSImage(size: NSSize(width: 1, height: 1))

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(x: 0, y: 0, width: 1, height: 1),
            contents: transparentImage
        )

        beginDraggingSession(with: [draggingItem], event: event, source: coordinator)
    }
}

// MARK: - Invisible Anchor (NSViewRepresentable)

private struct DragSourceAnchor: NSViewRepresentable {
    let item: HarborDragItem
    let icon: Image?
    let zoneID: DropZoneID
    let manager: HarborDragSessionManager

    func makeNSView(context: Context) -> HarborDragSourceNSView {
        let view = HarborDragSourceNSView()
        view.coordinator = context.coordinator
        view.registerWithManager()
        return view
    }

    func updateNSView(_ nsView: HarborDragSourceNSView, context: Context) {
        context.coordinator.item = item
        context.coordinator.icon = icon
        context.coordinator.zoneID = zoneID
    }

    static func dismantleNSView(_ nsView: HarborDragSourceNSView, coordinator: HarborDragSourceCoordinator) {
        nsView.unregisterFromManager()
    }

    func makeCoordinator() -> HarborDragSourceCoordinator {
        HarborDragSourceCoordinator(item: item, icon: icon, zoneID: zoneID, manager: manager)
    }
}

// MARK: - HarborDragSourceView

struct HarborDragSourceView<Content: View>: View {
    let item: HarborDragItem
    let icon: Image?
    let zoneID: DropZoneID
    let manager: HarborDragSessionManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                DragSourceAnchor(
                    item: item,
                    icon: icon,
                    zoneID: zoneID,
                    manager: manager
                )
            )
    }
}
