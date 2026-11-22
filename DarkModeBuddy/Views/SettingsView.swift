//
//  SettingsView.swift
//  DarkModeBuddy
//
//  Created by Guilherme Rambo on 23/02/21.
//

import SwiftUI
import DarkModeBuddyCore

struct SettingsView: View {
    @EnvironmentObject var reader: DMBAmbientLightSensorReader
    @EnvironmentObject var settings: DMBSettings

    private let darknessInterval: ClosedRange<Double> = 0...30000
    
    /// Finer steps at the low end, where typical indoor readings sit,
    /// with coarse steps up to bright rooms and direct daylight.
    private let darknessStops: [Double] = Array(stride(from: 0.0, to: 20, by: 1))
        + Array(stride(from: 20.0, to: 100, by: 5))
        + Array(stride(from: 100.0, to: 500, by: 25))
        + Array(stride(from: 500.0, to: 3000, by: 250))
        + Array(stride(from: 3000.0, to: 6000, by: 500))
        + Array(stride(from: 6000.0, through: 30000, by: 2000))
    
    private let revertMarginStops: [Double] = Array(stride(from: 1.0, to: 20, by: 1))
        + Array(stride(from: 20.0, to: 100, by: 5))
        + Array(stride(from: 100.0, through: 500, by: 25))
    
    private let delayStops: [Double] = Array(stride(from: 5.0, to: 60, by: 5))
        + Array(stride(from: 60.0, to: 300, by: 15))
        + Array(stride(from: 300.0, through: 600, by: 60))

    @State private var isShowingDarknessValueOutOfBoundsAlert = false
    @State private var isEditingAmbientLightLevelManually = false
    @State private var editingAmbientLightManuallyTextFieldStore = ""
    
    var body: some View {
        Group {
            if reader.isSensorReady {
                settingsControls
            } else {
                VStack(spacing: 20) {
                    UnsupportedMacView()
                    // So a VM forced into normal mode can be switched back to client mode.
                    VMModePicker()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding([.top, .bottom])
        .padding([.leading, .trailing], 22)
        .onAppear { reader.activate() }
    }
    
    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 32) {
            Toggle(
                "Launch at Login",
                isOn: $settings.isLaunchAtLoginEnabled
            )
            
            Toggle(
                "Show in Menu Bar",
                isOn: $settings.isMenuBarIconEnabled
            )
            
            Toggle(
                "Change Theme Automatically",
                isOn: $settings.isChangeSystemAppearanceBasedOnAmbientLightEnabled
            )
            
            Group {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go Dark When Ambient Light Falls Below:")
                    
                    HStack(alignment: .firstTextBaseline) {
                        SteppedSlider(value: $settings.darknessThreshold, stops: darknessStops)
                            .frame(maxWidth: 300)
                        if isEditingAmbientLightLevelManually {
                            TextField("", text: $editingAmbientLightManuallyTextFieldStore, onCommit: {
                                guard let newValue = Double(editingAmbientLightManuallyTextFieldStore),
                                      newValue >= darknessInterval.lowerBound,
                                      newValue <= darknessInterval.upperBound else {
                                    isShowingDarknessValueOutOfBoundsAlert = true
                                    return
                                }
                                settings.darknessThreshold = newValue
                                isEditingAmbientLightLevelManually = false
                            })
                            .frame(maxWidth: 40)
                        } else {
                            Text("\(settings.darknessThreshold.formattedNoFractionDigits)")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .onTapGesture(count: 2) {
                                    self.editingAmbientLightManuallyTextFieldStore = "\(settings.darknessThreshold.formattedNoFractionDigits)"
                                    isEditingAmbientLightLevelManually = true
                                }
                        }
                    }
                    .alert(isPresented: $isShowingDarknessValueOutOfBoundsAlert) {
                        Alert(title: Text("Error"),
                              message: Text("The threshold value must be in the interval [\(darknessInterval.lowerBound.formattedNoFractionDigits), \(darknessInterval.upperBound.formattedNoFractionDigits)]"),
                              dismissButton: .default(Text("OK")))
                    }
                    
                    HStack(alignment: .firstTextBaseline) {
                        Text("Current Ambient Light Level:")
                        Text("\(reader.ambientLightValue.formattedNoFractionDigits)")
                            .font(.system(size: 12).monospacedDigit())
                    }
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    
                    Text("Go Light Again When Ambient Light Rises Above:")
                        .padding(.top, 22)
                    
                    HStack(alignment: .firstTextBaseline) {
                        SteppedSlider(value: $settings.extraThresholdBeforeRevertingToLightMode, stops: revertMarginStops)
                            .frame(maxWidth: 300)
                        Text("\(settings.lightThreshold.formattedNoFractionDigits)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    
                    Text("Dark level + \(settings.extraThresholdBeforeRevertingToLightMode.formattedNoFractionDigits), to avoid flipping back and forth.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    
                    Text("Delay Time:")
                        .padding(.top, 22)
                    
                    HStack(alignment: .firstTextBaseline) {
                        SteppedSlider(value: $settings.darknessThresholdIntervalInSeconds, stops: delayStops)
                        Text(settings.darknessThresholdIntervalInSeconds.formattedTime)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            .disabled(!settings.isChangeSystemAppearanceBasedOnAmbientLightEnabled)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("With Lid Closed:")
                    
                    Picker("With Lid Closed:", selection: $settings.clamshellAppearance) {
                        ForEach(DMBSettings.ClamshellAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
                
                Text("When using an external display with the lid closed, use this theme and pause automatic switching, including macOS’ own.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    // A fixed width lets this wrap without inflating the window's minimum height.
                    .frame(width: 340, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Share Theme with Virtual Machines",
                    isOn: $settings.isVMSharingEnabled
                )
                
                if settings.isVMSharingEnabled {
                    TextField("Pairing Token (Optional)", text: $settings.vmSharingToken)
                        .frame(maxWidth: 220)
                }
                
                VMModePicker()
            }
            
            Text(settings.currentSettingsDescription)
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
//                .multilineTextAlignment(.center)
                .lineLimit(nil)
        }
    }
}

/// Picks between normal and VM client mode, which takes effect on the next launch.
struct VMModePicker: View {
    @EnvironmentObject var settings: DMBSettings
    
    @State private var launchMode: DMBSettings.VMMode?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mode:")
                
                Picker("Mode:", selection: $settings.vmMode) {
                    ForEach(DMBSettings.VMMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            
            if let launchMode = launchMode, launchMode != settings.vmMode {
                HStack(alignment: .firstTextBaseline) {
                    Text("Takes effect after relaunching.")
                    Button("Relaunch", action: relaunch)
                }
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
        }
        .onAppear { launchMode = launchMode ?? settings.vmMode }
    }
    
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        
        // Settings are written in didSet, so the new instance reads the new mode.
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { exit(0) }
        }
    }
}

/// Settings for client mode: where the host is and whether we're connected to it.
struct ClientSettingsView: View {
    @EnvironmentObject var client: DMBAppearanceSyncClient
    @EnvironmentObject var settings: DMBSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Following the theme of DarkModeBuddy on the host Mac.")
                .fixedSize(horizontal: false, vertical: true)
            
            Toggle("Launch at Login", isOn: $settings.isLaunchAtLoginEnabled)
            
            Toggle("Show in Menu Bar", isOn: $settings.isMenuBarIconEnabled)
            
            VStack(alignment: .leading, spacing: 6) {
                TextField("Host Address (Empty: Find Automatically)", text: $settings.vmClientHostAddress)
                TextField("Pairing Token (Optional)", text: $settings.vmSharingToken)
                
                Text(client.status)
                    .font(.system(size: 11))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            
            VMModePicker()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding([.top, .bottom])
        .padding([.leading, .trailing], 22)
        .padding(.top, 12)
    }
}

extension DMBSettings.VMMode {
    var title: String {
        switch self {
        case .automatic:
            return DMBVirtualMachine.isRunningInVirtualMachine ? "Automatic (VM Client)" : "Automatic (Normal)"
        case .normal:
            return "Normal"
        case .client:
            return "VM Client"
        }
    }
}

/// A slider that snaps to the given stops, with a haptic tick on each step.
struct SteppedSlider: View {
    @Binding var value: Double
    let stops: [Double]
    
    private var index: Binding<Double> {
        Binding(
            get: {
                let nearest = stops.indices.min { abs(stops[$0] - value) < abs(stops[$1] - value) } ?? 0
                return Double(nearest)
            },
            set: { newIndex in
                let newValue = stops[min(max(Int(newIndex.rounded()), 0), stops.count - 1)]
                guard newValue != value else { return }
                
                value = newValue
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        )
    }
    
    var body: some View {
        Slider(value: index, in: 0...Double(stops.count - 1), step: 1)
    }
}

extension NumberFormatter {
    static let noFractionDigits: NumberFormatter = {
        let f = NumberFormatter()
        
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        
        return f
    }()
}

extension Double {
    var formattedNoFractionDigits: String {
        NumberFormatter.noFractionDigits.string(from: NSNumber(value: self)) ?? "!!!"
    }
    var formattedTime: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        return (formatter.string(from: self) ?? "!!!" ) + "s"
    }
    var formattedLongTime: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        return formatter.string(from: self) ?? "!!!"
    }
}

extension DMBSettings {
    var currentSettingsDescription: String {
        guard isChangeSystemAppearanceBasedOnAmbientLightEnabled else {
            return "Dark Mode will not be enabled automatically based on ambient light."
        }
        
        return "Dark Mode will be enabled when the ambient light stays below \(darknessThreshold.formattedNoFractionDigits) for over \(darknessThresholdIntervalInSeconds.formattedLongTime), and Light Mode when it stays above \(lightThreshold.formattedNoFractionDigits) for as long."
    }
    
    /// The level ambient light must rise above to switch back from Dark Mode to Light Mode.
    var lightThreshold: Double {
        darknessThreshold + extraThresholdBeforeRevertingToLightMode
    }
}

extension DMBSettings.ClamshellAppearance {
    var title: String {
        switch self {
        case .unchanged:
            return "Don't Change"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(maxWidth: 385)
            .environmentObject(DMBAmbientLightSensorReader(frequency: .realtime))
            .environmentObject(DMBSettings(forPreview: true))
            .previewLayout(.sizeThatFits)
    }
}
