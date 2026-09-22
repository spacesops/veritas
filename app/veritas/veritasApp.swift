//
//  veritasApp.swift
//  veritas
//
//
//

import SwiftUI
import AppKit

@main
struct veritasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var fallbackWindow: NSWindow?
    private var contentController: NSHostingController<PopoverContentView>!
    private var veritas: Veritas!
    let viewModel = VeritasViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "VeritasStatusItem"
        statusItem.behavior = .removalAllowed

        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Initialize Veritas backend with sandbox-safe data directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dataDirURL = appSupport.appendingPathComponent("Veritas")
        try? FileManager.default.createDirectory(at: dataDirURL, withIntermediateDirectories: true)
        veritas = Veritas(dataDir: dataDirURL.path, external: nil, seeds: nil)

        viewModel.configure(veritas)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 570)
        popover.behavior = .transient
        popover.animates = true
        contentController = NSHostingController(
            rootView: PopoverContentView(viewModel: viewModel)
        )
        popover.contentViewController = contentController

        // Listen for share extension notifications
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShareNotification(_:)),
            name: NSNotification.Name("com.lcfx.veritas.shareQuery"),
            object: nil
        )

        NSApp.activate(ignoringOtherApps: true)
        // Status item layout (including notch clipping) is not ready until the next run loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.presentLaunchUI()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentLaunchUI()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Share Extension Handling

    @objc private func handleShareNotification(_ notification: Notification) {
        guard let query = notification.object as? String, !query.isEmpty else { return }
        handleIncomingQuery(query)
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "veritas" else { continue }

            if url.host == "search",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItem = components.queryItems?.first(where: { $0.name == "q" }),
               let query = queryItem.value {
                handleIncomingQuery(query)
            }
        }
    }

    private func handleIncomingQuery(_ query: String) {
        presentLaunchUI()
        viewModel.pendingShareQuery = query
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if isFallbackWindowVisible {
            fallbackWindow?.orderOut(nil)
            return
        }
        presentLaunchUI()
    }

    /// Show UI on launch, Dock click, and when the status item is unusable.
    private func presentLaunchUI() {
        NSApp.activate(ignoringOtherApps: true)
        if isStatusItemObscured {
            popover.performClose(nil)
            showFallbackWindow()
        } else {
            fallbackWindow?.orderOut(nil)
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            showFallbackWindow()
            return
        }
        fallbackWindow?.contentViewController = nil
        popover.contentViewController = contentController
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if let window = popover.contentViewController?.view.window {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    private func showFallbackWindow() {
        popover.performClose(nil)
        popover.contentViewController = nil
        if fallbackWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 570),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Veritas"
            window.isReleasedWhenClosed = false
            window.center()
            fallbackWindow = window
        }
        fallbackWindow?.contentViewController = contentController
        fallbackWindow?.makeKeyAndOrderFront(nil)
    }

    private var isFallbackWindowVisible: Bool {
        fallbackWindow?.isVisible ?? false
    }

    /// True when the extra is hidden, clipped, or sitting under the camera notch.
    private var isStatusItemObscured: Bool {
        if !statusItem.isVisible { return true }
        guard let button = statusItem.button, let window = button.window else { return true }

        let frame = window.frame
        if frame.width < 8 || frame.height < 8 { return true }

        guard let screen = window.screen ?? NSScreen.main else { return true }
        if !screen.frame.intersects(frame) { return true }

        if #available(macOS 12.0, *) {
            let left = screen.auxiliaryTopLeftArea ?? .zero
            let right = screen.auxiliaryTopRightArea ?? .zero
            if left.width > 0 || right.width > 0 {
                let mid = CGPoint(x: frame.midX, y: frame.midY)
                if !left.contains(mid) && !right.contains(mid) {
                    return true
                }
            }
        }

        return false
    }
}

// Wrapper that applies the glass background
struct PopoverContentView: View {
    @ObservedObject var viewModel: VeritasViewModel

    var body: some View {
        ContentView()
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(VisualEffectBackground())
            .overlay { NostrGlowOverlay(isActive: $viewModel.showNostrGlow) }
    }
}

/// Green border glow that pulses when a verified nostr message is found.
struct NostrGlowOverlay: View {
    @Binding var isActive: Bool
    @State private var glowOpacity: Double = 0

    var body: some View {
        if isActive {
            ZStack {
                // Soft outer glow
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.green.opacity(0.4), lineWidth: 2.5)
                    .blur(radius: 8)

                // Crisp inner edge
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.green.opacity(0.3), lineWidth: 1)
            }
            .opacity(glowOpacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    glowOpacity = 1
                }
            }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .dark
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
