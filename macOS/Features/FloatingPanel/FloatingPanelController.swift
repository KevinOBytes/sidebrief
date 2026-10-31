import SwiftUI
import AppKit

@MainActor
public final class FloatingPanelController: NSWindowController {
    public static let shared = FloatingPanelController()

    private var panel: NSPanel?
    private var hasPositionedInitially: Bool = false
    private weak var previouslyVisibleMainWindow: NSWindow?

    public var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

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
        // Stealth Mode: Window is excluded from screen capture (Zoom, Google Meet, Microsoft Teams, Slack screen shares)
        panel.sharingType = .none
        panel.minSize = NSSize(width: 320, height: 180)
        panel.maxSize = NSSize(width: 600, height: 900)
        panel.setFrameAutosaveName("SidebriefFloatingPanelAutosave")

        super.init(window: panel)
        self.panel = panel
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showPanel(with view: AnyView, hideMainWindow: Bool = true) {
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

        // Animate main window fade out if requested
        if hideMainWindow {
            if let mainWindow = NSApplication.shared.windows.first(where: { $0 != panel && !($0 is NSPanel) && $0.isVisible }) {
                self.previouslyVisibleMainWindow = mainWindow
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    mainWindow.animator().alphaValue = 0.0
                }, completionHandler: {
                    Task { @MainActor in
                        mainWindow.orderOut(nil)
                        mainWindow.alphaValue = 1.0
                    }
                })
            }
        }

        // Animate HUD panel fade in
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1.0
        }
    }

    public func hidePanel() {
        hidePanelAndRestoreMainWindow()
    }

    public func hidePanelAndRestoreMainWindow() {
        guard let panel = self.panel else { return }

        // Animate HUD panel fade out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1.0
            }
        })

        // Restore main window with smooth fade in
        let targetWindow = self.previouslyVisibleMainWindow ?? NSApplication.shared.windows.first(where: { $0 != panel && !($0 is NSPanel) })
        if let mainWindow = targetWindow {
            mainWindow.alphaValue = 0.0
            mainWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                mainWindow.animator().alphaValue = 1.0
            }
        }
    }

    public func togglePanel(with view: AnyView) {
        if isPanelVisible {
            hidePanelAndRestoreMainWindow()
        } else {
            showPanel(with: view, hideMainWindow: true)
        }
    }
}
