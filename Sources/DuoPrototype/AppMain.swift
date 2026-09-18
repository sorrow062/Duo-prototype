import AppKit
import CoreAudio
import IOKit.ps
import Network
import ServiceManagement
import Sparkle
import SwiftUI

enum NetworkState: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case hotspot = "个人热点"
    case ethernet = "以太网"
    case offline = "断开"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .hotspot: "personalhotspot"
        case .ethernet: "cable.connector.horizontal"
        case .offline: "wifi.slash"
        }
    }

    var detail: String {
        switch self {
        case .wifi: "Home Wi-Fi"
        case .hotspot: "个人热点"
        case .ethernet: "Ethernet"
        case .offline: "没有网络连接"
        }
    }
}

enum AudioState: String, CaseIterable, Identifiable {
    case none = "无耳机"
    case airpods = "AirPods"
    case headphones = "蓝牙耳机"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .none: "speaker.wave.2"
        case .airpods: "airpodspro"
        case .headphones: "headphones"
        }
    }
}

extension Notification.Name {
    static let duoOpenControlCenter = Notification.Name("DuoPrototype.openControlCenter")
}

enum ThermalPressure: String {
    case nominal = "正常"
    case fair = "轻微"
    case serious = "较高"
    case critical = "严重"

    var isElevated: Bool { self == .serious || self == .critical }
}

struct ResourceMetrics: Equatable {
    var cpuUsage = 0.0
    var memoryUsage = 0.0
    var thermal = ThermalPressure.nominal

    var needsAttention: Bool {
        cpuUsage >= 0.70 || memoryUsage >= 0.85 || thermal.isElevated
    }

    var summary: String {
        var parts: [String] = []
        if cpuUsage >= 0.70 { parts.append("CPU \(Int(cpuUsage * 100))%") }
        if memoryUsage >= 0.85 { parts.append("内存 \(Int(memoryUsage * 100))%") }
        if thermal.isElevated { parts.append("热压力 \(thermal.rawValue)") }
        return parts.joined(separator: " · ")
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let isBluetooth: Bool

    var symbol: String { isBluetooth ? "dot.radiowaves.left.and.right" : "speaker.wave.2" }
}

@MainActor
final class PrototypeModel: ObservableObject {
    static let shared = PrototypeModel()

    @Published var battery: Double = 0
    @Published var network: NetworkState = .offline
    @Published var volume: Double = 0
    @Published var isCharging = false
    @Published var chargingMinutesRemaining: Int?
    @Published var lowPowerModeEnabled = false
    @Published var audio: AudioState = .none
    @Published var audioDeviceName = ""
    @Published var outputDevices: [OutputDevice] = []
    @Published var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published var isMuted = false
    @Published var lastUpdated = Date()
    @Published var showPercentage = true
    @Published var lastEvent: StatusEvent?
    @Published var metrics = ResourceMetrics()

    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.local.duo-prototype.network")
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var previousCPUTicks: [UInt64] = []

    init(startMonitoring: Bool = true) {
        if startMonitoring { self.startMonitoring() }
    }

    var batteryPercentage: Int { Int((battery * 100).rounded()) }
    var activeDots: Int {
        guard volume > 0.01 else { return 0 }
        return min(4, max(1, Int(ceil(volume * 4))))
    }

    var batteryColor: Color {
        if isCharging { return .green }
        if battery <= 0.10 { return .red }
        return .primary
    }

    var networkDescription: String {
        switch network {
        case .wifi: "Wi-Fi 已连接"
        case .hotspot: "个人热点已连接"
        case .ethernet: "以太网已连接"
        case .offline: "网络已断开"
        }
    }

    var connectionDetail: String {
        switch network {
        case .wifi: "Wi‑Fi 网络"
        case .hotspot: "个人热点连接"
        case .ethernet: "以太网连接"
        case .offline: "没有活动网络"
        }
    }

    func refresh() {
        let previousBattery = battery
        let previousCharging = isCharging
        let previousNetwork = network
        let previousAudio = audio
        readPower()
        readAudio()
        readSystemMetrics()
        lastUpdated = Date()

        if !previousCharging && isCharging {
            flash(.charging)
        } else if previousBattery > 0.10 && battery <= 0.10 && !isCharging {
            flash(.lowBattery)
        } else if previousNetwork != .offline && network == .offline {
            flash(.networkDisconnected)
        } else if previousAudio != audio && audio != .none {
            flash(.audioConnected(audio))
        }
    }

    private func startMonitoring() {
        refresh()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let state: NetworkState
            if path.status != .satisfied {
                state = .offline
            } else if path.usesInterfaceType(.wifi) {
                state = path.isExpensive ? .hotspot : .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                state = .ethernet
            } else {
                state = .ethernet
            }
            Task { @MainActor in
                guard let self else { return }
                let previous = self.network
                self.network = state
                self.lastUpdated = Date()
                if previous != state {
                    if state == .offline {
                        self.flash(.networkDisconnected)
                    }
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func readPower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        guard let source = sourceList.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else { return }

        if let current = description[kIOPSCurrentCapacityKey] as? Int,
           let maximum = description[kIOPSMaxCapacityKey] as? Int,
           maximum > 0 {
            battery = min(1, max(0, Double(current) / Double(maximum)))
        }
        let state = description[kIOPSPowerSourceStateKey] as? String
        isCharging = state == kIOPSACPowerValue && battery < 0.999
        if isCharging,
           let minutes = description[kIOPSTimeToFullChargeKey] as? Int,
           minutes >= 0 {
            chargingMinutesRemaining = minutes
        } else {
            chargingMinutesRemaining = nil
        }
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var chargingEstimateText: String? {
        guard isCharging else { return nil }
        guard let minutes = chargingMinutesRemaining else { return "正在估算充满时间…" }
        if minutes <= 1 { return "即将充满" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return remainder > 0 ? "预计还需 \(hours) 小时 \(remainder) 分钟充满" : "预计还需 \(hours) 小时充满"
        }
        return "预计还需 \(remainder) 分钟充满"
    }

    var powerStatusText: String {
        if let estimate = chargingEstimateText { return "正在充电 · \(estimate)" }
        return "使用电池"
    }

    func setLowPowerMode(_ enabled: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let value = enabled ? "1" : "0"
        let script = "do shell script \"/usr/bin/pmset -b lowpowermode \(value)\" with administrator privileges"
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            refresh()
            if lowPowerModeEnabled != enabled { openBatterySettings() }
        } catch {
            openBatterySettings()
        }
    }

    private func readSystemMetrics() {
        let cpu = readCPUUsage()
        var memory = vmMemoryUsage()
        if !memory.isFinite { memory = 0 }
        let thermal: ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }
        metrics = ResourceMetrics(cpuUsage: cpu, memoryUsage: memory, thermal: thermal)
    }

    private func readCPUUsage() -> Double {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount) == KERN_SUCCESS,
              let cpuInfo else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let stride = Int(CPU_STATE_MAX)
        var current = Array(repeating: UInt64(0), count: Int(cpuCount) * stride)
        for index in current.indices { current[index] = UInt64(max(0, cpuInfo[index])) }
        guard previousCPUTicks.count == current.count else {
            previousCPUTicks = current
            return 0
        }
        var totalDelta: UInt64 = 0
        var activeDelta: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            for state in 0..<stride {
                let delta = current[base + state] &- previousCPUTicks[base + state]
                totalDelta &+= delta
                if state != Int(CPU_STATE_IDLE) { activeDelta &+= delta }
            }
        }
        previousCPUTicks = current
        guard totalDelta > 0 else { return 0 }
        return min(1, Double(activeDelta) / Double(totalDelta))
    }

    private func vmMemoryUsage() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let totalPages = UInt64(ProcessInfo.processInfo.physicalMemory) / UInt64(vm_page_size)
        guard totalPages > 0 else { return 0 }
        return min(1, Double(usedPages) / Double(totalPages))
    }

    private func readAudio() {
        let device = defaultOutputDevice()
        outputDevices = availableOutputDevices()
        outputDeviceID = device
        guard device != kAudioObjectUnknown else {
            volume = 0
            audio = .none
            audioDeviceName = "无输出设备"
            isMuted = false
            return
        }
        if let value = scalarVolume(device) {
            volume = min(1, max(0, value))
        }
        isMuted = muteState(device) ?? false
        let name = deviceName(device) ?? "系统输出"
        audioDeviceName = name
        let normalized = name.lowercased()
        if normalized.contains("airpods") {
            audio = .airpods
        } else if normalized.contains("headphone") || normalized.contains("耳机") {
            audio = .headphones
        } else {
            audio = .none
        }
    }

    private func availableOutputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { device in
            guard hasOutputChannels(device), let name = deviceName(device) else { return nil }
            return OutputDevice(id: device, name: name, isBluetooth: isBluetoothDevice(device))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func hasOutputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let bufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(bufferList).contains { $0.mNumberChannels > 0 }
    }

    private func isBluetoothDevice(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func setOutputDevice(_ device: AudioDeviceID) {
        guard device != kAudioObjectUnknown else { return }
        var selected = device
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &selected) == noErr {
            refresh()
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private func scalarVolume(_ device: AudioDeviceID) -> Double? {
        // Bluetooth headsets often expose volume on channels 1/2 but not on
        // the master element. Read the channel values first, then fall back
        // to the master element for devices that only provide it.
        let elements: [UInt32] = [1, 2, kAudioObjectPropertyElementMain]
        var values: [Double] = []
        for element in elements {
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                values.append(Double(value))
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func muteState(_ device: AudioDeviceID) -> Bool? {
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        var values: [Bool] = []
        for element in elements {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                values.append(value != 0)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.contains(true)
    }

    func setVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        let elements: [UInt32] = [1, 2, kAudioObjectPropertyElementMain]
        var wrote = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var scalar = Float32(clamped)
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar) == noErr {
                wrote = true
            }
        }
        if wrote {
            refresh()
        }
    }

    func setMuted(_ muted: Bool) {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        var wrote = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value = muted ? UInt32(1) : UInt32(0)
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                wrote = true
            }
        }
        if wrote {
            refresh()
        }
    }

    func openNetworkSettings() {
        let urlString: String
        switch network {
        case .wifi, .hotspot: urlString = "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case .ethernet: urlString = "x-apple.systempreferences:com.apple.Network-Settings.extension?Ethernet"
        case .offline: urlString = "x-apple.systempreferences:com.apple.Network-Settings.extension"
        }
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The user can approve the login item from System Settings when required.
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private func deviceName(_ device: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private func flash(_ event: StatusEvent) {
        lastEvent = event
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.lastEvent = nil
        }
    }

    deinit {
        refreshTimer?.invalidate()
        networkMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}

enum StatusEvent: Equatable {
    case charging
    case lowBattery
    case networkDisconnected
    case audioConnected(AudioState)

    var title: String {
        switch self {
        case .charging: "正在充电"
        case .lowBattery: "电量偏低"
        case .networkDisconnected: "网络已断开"
        case .audioConnected(let audio): "已连接 \(audio.rawValue)"
        }
    }
}

struct BatteryArcShape: Shape {
    var progress: CGFloat
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let drawingRect = rect.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: drawingRect.midX, y: drawingRect.midY)
        let radius = min(drawingRect.width, drawingRect.height) / 2
        let start = Angle(degrees: 138)
        let end = start + Angle(degrees: 264 * Double(min(max(progress, 0), 1)))
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}

struct DuoGlyphView: View {
    @ObservedObject var model: PrototypeModel
    var size: CGFloat = 96

    private var isMenuBarSize: Bool { size <= 32 }
    private var ringWidth: CGFloat { isMenuBarSize ? max(1.9, size * 0.087) : size * 0.075 }
    private var centerSymbolSize: CGFloat { size * (isMenuBarSize ? 0.40 : 0.22) }
    private var dotSize: CGFloat { size * (isMenuBarSize ? 0.088 : 0.075) }

    var body: some View {
        ZStack {
            BatteryArcShape(progress: 1, inset: ringWidth / 2)
                .stroke(.primary.opacity(0.13), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))

            BatteryArcShape(progress: model.battery, inset: ringWidth / 2)
                .stroke(model.batteryColor, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .animation(.easeInOut(duration: 0.35), value: model.battery)

            if model.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * (isMenuBarSize ? 0.19 : 0.16), weight: .bold))
                    .foregroundStyle(.green)
                    .offset(x: size * 0.30, y: -size * 0.29)
                    .transition(.scale.combined(with: .opacity))
            }

            Image(systemName: model.audio == .none ? model.network.symbol : model.audio.symbol)
                .font(.system(size: centerSymbolSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.network == .offline ? .red : .primary)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.22), value: model.network)
                .animation(.easeInOut(duration: 0.22), value: model.audio)

            HStack(spacing: size * (isMenuBarSize ? 0.05 : 0.055)) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(dotStyle(for: index))
                        .frame(width: dotSize, height: dotSize)
                        .animation(.easeInOut(duration: 0.18), value: model.activeDots)
                        .animation(.easeInOut(duration: 0.18), value: model.isMuted)
                }
            }
            .offset(y: size * (isMenuBarSize ? 0.29 : 0.30))
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电量 \(model.batteryPercentage)%，\(model.networkDescription)")
    }

    private func dotStyle(for index: Int) -> AnyShapeStyle {
        if model.isMuted {
            return AnyShapeStyle(Color.gray.opacity(0.62))
        }
        return index < model.activeDots
            ? AnyShapeStyle(.primary)
            : AnyShapeStyle(.primary.opacity(0.18))
    }
}

struct PrototypeWindow: View {
    @ObservedObject var model: PrototypeModel
    @State private var isDark = true
    @State private var showControlPanel = false

    var body: some View {
        ZStack {
            (isDark ? Color(red: 0.055, green: 0.06, blue: 0.075) : Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Duo Prototype")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("菜单栏状态图标视觉原型")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("深色", isOn: $isDark)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Button("打开控制面板") { showControlPanel = true }
                            .buttonStyle(.borderedProminent)
                            .popover(isPresented: $showControlPanel, arrowEdge: .top) {
                                CompactPanel(model: model)
                            }
                    }

                    HStack(alignment: .top, spacing: 18) {
                        previewCard
                        controlsCard
                    }

                    stateStrip
                }
                .padding(30)
                .frame(maxWidth: 980)
            }
        }
        .preferredColorScheme(isDark ? .dark : .light)
        .frame(minWidth: 920, minHeight: 620)
    }

    private var previewCard: some View {
        VStack(spacing: 16) {
            HStack {
                Label("菜单栏预览", systemImage: "menubar.rectangle")
                    .font(.headline)
                Spacer()
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.12), in: Capsule())
            }

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                VStack(spacing: 18) {
                    DuoGlyphView(model: model, size: 174)
                    VStack(spacing: 4) {
                        Text("\(model.batteryPercentage)%")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text(model.networkDescription)
                            .foregroundStyle(.secondary)
                    }
                    if let event = model.lastEvent {
                        Label(event.title, systemImage: "sparkles")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(model.batteryColor)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(34)
            }
            .frame(height: 360)

            Text("外圈 = 电量 · 中心 = 网络/耳机 · 四点 = 音量")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("实时状态", systemImage: "waveform")
                .font(.headline)

            liveRow(title: "电量", value: "\(model.batteryPercentage)%", symbol: "battery.100percent")
            liveRow(title: "电源", value: model.isCharging ? "正在充电" : "使用电池", symbol: model.isCharging ? "bolt.fill" : "battery.100percent")
            liveRow(title: "网络", value: model.networkDescription, symbol: model.network.symbol)
            liveRow(title: "音量", value: "\(Int(model.volume * 100))%", symbol: "speaker.wave.2")
            liveRow(title: "输出", value: model.audioDeviceName.isEmpty ? "系统输出" : model.audioDeviceName, symbol: model.audio.symbol)

            Divider()

            Text("数据来自当前 Mac · 每 2 秒更新")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("立即刷新") { model.refresh() }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 300)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func controlRow<Content: View>(title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func liveRow(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline)
            }
            Spacer()
        }
    }

    private var stateStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关键状态")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                statePreview("正常", .wifi, 0.64, false, .none)
                statePreview("充电", .wifi, 0.82, true, .none)
                statePreview("低电量", .wifi, 0.08, false, .none)
                statePreview("耳机", .wifi, 0.64, false, .airpods)
                statePreview("断网", .offline, 0.64, false, .none)
                statePreview("静音", .wifi, 0.75, false, .none, muted: true)
            }
        }
    }

    private func statePreview(_ title: String, _ network: NetworkState, _ battery: Double, _ charging: Bool, _ audio: AudioState, muted: Bool = false) -> some View {
        VStack(spacing: 7) {
            DuoGlyphView(model: previewModel(network: network, battery: battery, charging: charging, audio: audio, muted: muted), size: 48)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func previewModel(network: NetworkState, battery: Double, charging: Bool, audio: AudioState, muted: Bool = false) -> PrototypeModel {
        let preview = PrototypeModel(startMonitoring: false)
        preview.network = network
        preview.battery = battery
        preview.isCharging = charging
        preview.audio = audio
        preview.volume = 0.75
        preview.isMuted = muted
        return preview
    }
}

struct CompactPanel: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                DuoGlyphView(model: model, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.networkDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.batteryPercentage)%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            Divider()

            compactRow("网络", model.networkDescription, model.network.symbol) {
                model.openNetworkSettings()
            }
            compactRow("电量", model.powerStatusText, model.isCharging ? "bolt.fill" : "battery.100percent") {
                model.openBatterySettings()
            }

            HStack(spacing: 10) {
                Image(systemName: model.lowPowerModeEnabled ? "leaf.fill" : "leaf")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("低电量模式").font(.caption).foregroundStyle(.secondary)
                    Text(model.lowPowerModeEnabled ? "已开启" : "已关闭").font(.subheadline)
                }
                Spacer()
                Toggle("低电量模式", isOn: Binding(
                    get: { model.lowPowerModeEnabled },
                    set: { model.setLowPowerMode($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("音量", systemImage: model.isMuted ? "speaker.slash" : "speaker.wave.2")
                    Spacer()
                    Text(model.isMuted ? "静音" : "\(Int(model.volume * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                    in: 0...1
                )
                Toggle("静音", isOn: Binding(get: { model.isMuted }, set: { model.setMuted($0) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("输出设备", systemImage: model.audio.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("输出设备", selection: Binding(
                    get: { model.outputDeviceID },
                    set: { model.setOutputDevice($0) }
                )) {
                    if !model.outputDevices.filter(\.isBluetooth).isEmpty {
                        Section("蓝牙设备") {
                            ForEach(model.outputDevices.filter(\.isBluetooth)) { device in
                                Label(device.name, systemImage: device.symbol)
                                    .tag(device.id)
                            }
                        }
                    }
                    if !model.outputDevices.filter({ !$0.isBluetooth }).isEmpty {
                        Section("Mac 与其他输出") {
                            ForEach(model.outputDevices.filter { !$0.isBluetooth }) { device in
                                Label(device.name, systemImage: device.symbol)
                                    .tag(device.id)
                            }
                        }
                    }
                    if model.outputDevices.isEmpty {
                        Text("没有可用输出设备").tag(kAudioObjectUnknown)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text(model.audioDeviceName.isEmpty ? "系统输出" : model.audioDeviceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.metrics.needsAttention {
                VStack(alignment: .leading, spacing: 5) {
                    Label("需要关注", systemImage: "gauge.with.needle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(model.metrics.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("自动监测 CPU、内存和热压力")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }

            Divider()

            HStack(spacing: 8) {
                Button("控制中心") {
                    NotificationCenter.default.post(name: .duoOpenControlCenter, object: nil)
                }
                .buttonStyle(.bordered)
                Button("刷新") { model.refresh() }
                    .buttonStyle(.bordered)
                Toggle("登录启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            Button("检查更新…") {
                AppUpdater.shared.checkForUpdates()
            }
            .disabled(!AppUpdater.shared.isConfigured)
            .font(.caption)
        }
        .padding(16)
        .frame(width: 330)
    }

    private func compactRow(_ title: String, _ detail: String, _ symbol: String, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.subheadline)
            }
            Spacer()
            if let action {
                Button("打开") { action() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingView: NSHostingView<MenuBarGlyph>!
    private var controlCenterObserver: NSObjectProtocol?
    private var controlCenterWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppUpdater.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: 36)
        guard let button = statusItem.button else { return }
        button.toolTip = "Duo Prototype"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        hostingView = NSHostingView(rootView: MenuBarGlyph(model: PrototypeModel.shared))
        hostingView.frame = NSRect(x: 0, y: 0, width: 36, height: 24)
        hostingView.autoresizingMask = [.width, .height]
        button.addSubview(hostingView)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: CompactPanel(model: PrototypeModel.shared))

        controlCenterObserver = NotificationCenter.default.addObserver(
            forName: .duoOpenControlCenter, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showControlCenter()
        }

    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showControlCenter() {
        popover.performClose(nil)
        if let window = controlCenterWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Duo Prototype"
        window.contentView = NSHostingView(rootView: PrototypeWindow(model: PrototypeModel.shared))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        controlCenterWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === controlCenterWindow {
            controlCenterWindow = nil
        }
    }

    deinit {
        if let controlCenterObserver {
            NotificationCenter.default.removeObserver(controlCenterObserver)
        }
    }
}

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    func start() {
        guard controller == nil,
              let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              feedURL.hasPrefix("https://"),
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty,
              !publicKey.contains("REPLACE")
        else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

struct MenuBarGlyph: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        DuoGlyphView(model: model, size: 24)
            .frame(width: 36, height: 24)
    }
}

@main
struct DuoPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PrototypeModel.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
