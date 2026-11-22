//
//  AppDelegate.swift
//  DarkModeBuddy
//
//  Created by Guilherme Rambo on 23/02/21.
//

import Cocoa
import SwiftUI
import DarkModeBuddyCore
import Sparkle
import Combine

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    
    let settings = DMBSettings()

    lazy var switcher: DMBSystemAppearanceSwitcher = {
        DMBSystemAppearanceSwitcher(settings: settings)
    }()
    
    private var shouldShowUI: Bool {
        !settings.hasLaunchedAppBefore
        || shouldShowSettingsOnNextLaunch
        || UserDefaults.standard.bool(forKey: "ShowSettings")
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        SUUpdater.shared()?.delegate = self
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Decided once per launch: client mode never creates the switcher, so no sensor is read.
        isClientMode = settings.isVMClientModeSelected
        
        if shouldShowUI {
            settings.hasLaunchedAppBefore = true
            showSettingsWindow(nil)
        }
        
        if isClientMode {
            startSyncClient()
        } else {
            switcher.activate()
            startSyncHost()
        }
        
        statusItemController = StatusItemController(
            settings: settings,
            source: isClientMode ? .client(syncClient) : .ambientLight(switcher.reader)
        ) { [weak self] in
            self?.showSettingsWindow(nil)
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(receivedShutdownNotification),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
    }
    
    private var statusItemController: StatusItemController?
    
    // MARK: - Virtual machines
    
    private var isClientMode = false
    
    private let syncClient = DMBAppearanceSyncClient()
    
    private var syncHost: DMBAppearanceSyncHost?
    
    private var syncCancellables = Set<AnyCancellable>()
    
    /// Shares the theme while enabled, restarting whenever the token changes.
    private func startSyncHost() {
        settings.$isVMSharingEnabled
            .combineLatest(settings.$vmSharingToken.debounce(for: .seconds(1), scheduler: DispatchQueue.main))
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] isEnabled, token in
                self?.syncHost?.stop()
                self?.syncHost = nil
                
                guard isEnabled else { return }
                
                let host = DMBAppearanceSyncHost(token: token)
                host.start()
                self?.syncHost = host
            }
            .store(in: &syncCancellables)
    }
    
    /// Follows the host, reconnecting whenever its address or the token changes.
    private func startSyncClient() {
        settings.$vmClientHostAddress
            .combineLatest(settings.$vmSharingToken)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] address, token in
                self?.syncClient.start(hostAddress: address, token: token)
            }
            .store(in: &syncCancellables)
    }
    
    private lazy var sensorReader = DMBAmbientLightSensorReader(frequency: .realtime)

    @IBAction func showSettingsWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        
        guard !isShowingSettingsWindow else {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 385, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("Settings")
        window.titlebarAppearsTransparent = true
        window.title = "DarkModeBuddy Settings"
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        
        if isClientMode {
            let view = ClientSettingsView()
                .environmentObject(syncClient)
                .environmentObject(settings)
            
            window.contentView = NSHostingView(rootView: view)
            window.setContentSize(NSSize(width: 385, height: 330))
        } else {
            let view = SettingsView()
                .environmentObject(sensorReader)
                .environmentObject(settings)
            
            window.contentView = NSHostingView(rootView: view)
            // The autosaved frame may predate the virtual machine controls.
            window.setContentSize(NSSize(width: 385, height: 700))
        }
        
        window.makeKeyAndOrderFront(nil)
        window.center()
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func terminate(_ sender: Any?) {
        // No need to confirm on quit if the user's Mac is not supported.
        // Nor in client mode, where quitting only stops following the host.
        shouldSkipTerminationConfirmation = isClientMode || !sensorReader.isSensorReady
        
        NSApp.terminate(sender)
    }

    private var isShowingSettingsWindow: Bool {
        guard let window = window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isShowingSettingsWindow else { return true }
        
        showSettingsWindow(nil)
        
        return true
    }
    
    private var shouldShowSettingsOnNextLaunch: Bool {
        get {
            let value = UserDefaults.standard.bool(forKey: #function)
            
            if value {
                // Reset flag
                UserDefaults.standard.set(false, forKey: #function)
            }
            
            return value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: #function)
            UserDefaults.standard.synchronize()
        }
    }
    
    private var shouldSkipTerminationConfirmation = false
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shouldSkipTerminationConfirmation else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit DarkModeBuddy?"
        alert.informativeText = "If you quit DarkModeBuddy, it won't be able to monitor your ambient light level and change the system theme automatically. Would you like to hide DarkModeBuddy instead?"
        alert.addButton(withTitle: "Hide DarkModeBuddy")
        alert.addButton(withTitle: "Quit")

        let result = alert.runModal()

        if result == .alertSecondButtonReturn {
            return .terminateNow
        } else {
            window?.close()
            
            return .terminateCancel
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        syncHost?.stop()
        
        // Don't leave the system stuck on the clamshell theme with macOS' automatic switching off.
        if !isClientMode {
            switcher.endClamshellOverride()
        }
    }
    
    @objc func receivedShutdownNotification(_ note: Notification) {
        shouldSkipTerminationConfirmation = true
    }

}

extension AppDelegate: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        
        NSApp.setActivationPolicy(.accessory)
        
        window = nil
    }
    
}

extension AppDelegate: SUUpdaterDelegate {
    
    func updaterWillRelaunchApplication(_ updater: SUUpdater) {
        shouldSkipTerminationConfirmation = true
        shouldShowSettingsOnNextLaunch = true
    }
    
    func updater(_ updater: SUUpdater, didCancelInstallUpdateOnQuit item: SUAppcastItem) {
        shouldSkipTerminationConfirmation = false
    }
    
}
