import SwiftUI
import AppKit

public final class FloatingPanelController: NSWindowController, @unchecked Sendable {
    public static let shared = FloatingPanelController()

    private var panel: NSPanel?
    private var hasPositionedInitially: Bool = false

    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 460, height: 600),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )

        panel.title = "Sidebrief Copilot"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 380, height: 400)
        panel.maxSize = NSSize(width: 600, height: 900)
        panel.setFrameAutosaveName("SidebriefFloatingPanelAutosave")

        super.init(window: panel)
        self.panel = panel
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showPanel(with view: AnyView) {
        guard let panel = self.panel else { return }
        panel.contentView = NSHostingView(rootView: view)

        if !hasPositionedInitially {
            let restored = panel.setFrameUsingName("SidebriefFloatingPanelAutosave")
            if !restored, let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let x = screenRect.maxX - 480
                let y = screenRect.midY - 300
                panel.setFrame(NSRect(x: x, y: y, width: 460, height: 600), display: true)
            }
            hasPositionedInitially = true
        }

        panel.orderFrontRegardless()
    }

    public func hidePanel() {
        panel?.orderOut(nil)
    }

    public func togglePanel(with view: AnyView) {
        if let panel = panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel(with: view)
        }
    }
}
