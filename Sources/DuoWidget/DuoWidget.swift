import CoreAudio
import IOKit.ps
import Network
import SwiftUI
import WidgetKit

private enum WidgetNetworkState {
    case wifi
    case hotspot
    case ethernet
    case offline

    var label: String {
        switch self {
        case .wifi: "Wi-Fi 已连接"
        case .hotspot: "个人热点已连接"
        case .ethernet: "以太网已连接"
        case .offline: "网络已断开"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .hotspot: "personalhotspot"
        case .ethernet: "cable.connector.horizontal"
        case .offline: "wifi.slash"
        }
    }
}

private struct DuoWidgetEntry: TimelineEntry {
    let date: Date
    let battery: Int
    let isCharging: Bool
    let network: WidgetNetworkState
    let volume: Int
    let isMuted: Bool
    let outputName: String
    let audioSymbol: String

    static let placeholder = DuoWidgetEntry(
        date: .now,
        battery: 72,
        isCharging: false,
        network: .wifi,
        volume: 64,
        isMuted: false,
        outputName: "Mac 扬声器",
        audioSymbol: "speaker.wave.2"
    )
}

private struct DuoWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DuoWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (DuoWidgetEntry) -> Void) {
        completion(readCurrentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DuoWidgetEntry>) -> Void) {
        let entry = readCurrentEntry()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func readCurrentEntry() -> DuoWidgetEntry {
        let power = readPower()
        let audio = readAudio()
        return DuoWidgetEntry(
            date: .now,
            battery: power.percentage,
            isCharging: power.isCharging,
            network: readNetwork(),
            volume: audio.volume,
            isMuted: audio.isMuted,
            outputName: audio.name,
            audioSymbol: audio.symbol
        )
    }

    private func readPower() -> (percentage: Int, isCharging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (0, false) }
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else { return (0, false) }
        let percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        let powerState = description[kIOPSPowerSourceStateKey] as? String
        return (percentage, powerState == kIOPSACPowerValue && percentage < 100)
    }

    private func readNetwork() -> WidgetNetworkState {
        let monitor = NWPathMonitor()
        let result = NetworkResult()
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            if path.status != .satisfied {
                result.set(.offline)
            } else if path.usesInterfaceType(.wifi) {
                result.set(path.isExpensive ? .hotspot : .wifi)
            } else {
                result.set(.ethernet)
            }
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.local.duo-widget.network"))
        _ = semaphore.wait(timeout: .now() + 0.8)
        monitor.cancel()
        return result.get()
    }

    private func readAudio() -> (volume: Int, isMuted: Bool, name: String, symbol: String) {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &deviceSize, &device) == noErr,
              device != kAudioObjectUnknown else {
            return (0, false, "无输出设备", "speaker.slash")
        }

        // Bluetooth devices may expose volume on channels 1/2 instead of the
        // master element. Read all available output elements and average them.
        let volumeElements: [UInt32] = [1, 2, kAudioObjectPropertyElementMain]
        var volumeValues: [Double] = []
        for element in volumeElements {
            var scalar = Float32(0)
            var scalarSize = UInt32(MemoryLayout<Float32>.size)
            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &volumeAddress) else { continue }
            if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &scalarSize, &scalar) == noErr {
                volumeValues.append(Double(scalar))
            }
        }
        let scalar = volumeValues.isEmpty ? 0 : volumeValues.reduce(0, +) / Double(volumeValues.count)

        var muteValues: [Bool] = []
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var candidate = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &candidate) else { continue }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &candidate, 0, nil, &size, &value) == noErr {
                muteValues.append(value != 0)
            }
        }
        let isMuted = muteValues.contains(true)

        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let name: String
        if AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &unmanagedName) == noErr,
           let unmanagedName {
            name = unmanagedName.takeUnretainedValue() as String
        } else {
            name = "系统输出"
        }
        let normalized = name.lowercased()
        let symbol = normalized.contains("airpods") ? "airpodspro" :
            (normalized.contains("headphone") || normalized.contains("耳机") ? "headphones" : "speaker.wave.2")
        return (Int((min(1, max(0, scalar)) * 100).rounded()), isMuted, name, symbol)
    }
}

private final class NetworkResult: @unchecked Sendable {
    private let lock = NSLock()
    private var state: WidgetNetworkState = .offline

    func set(_ newState: WidgetNetworkState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    func get() -> WidgetNetworkState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

private struct DuoWidgetArc: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(138),
            endAngle: .degrees(138 + 264 * Double(min(max(progress, 0), 1))),
            clockwise: false
        )
        return path
    }
}

private struct DuoWidgetView: View {
    let entry: DuoWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var batteryTint: Color {
        if entry.isCharging { return .green }
        if entry.battery <= 10 { return .red }
        return .primary
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Duo", systemImage: "circle.hexagongrid.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                if entry.isCharging {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                }
            }
            Spacer(minLength: 2)
            HStack(spacing: 10) {
                glyph(size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.battery)%")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Label(entry.network.label, systemImage: entry.network.symbol)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 2)
            volumeDots
        }
        .padding(4)
    }

    private var mediumLayout: some View {
        HStack(spacing: 18) {
            glyph(size: 82)
                .frame(width: 92)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(entry.battery)%")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if entry.isCharging {
                        Label("充电中", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Label(entry.network.label, systemImage: entry.network.symbol)
                    .font(.caption)
                HStack(spacing: 6) {
                    Image(systemName: entry.isMuted ? "speaker.slash" : "speaker.wave.2")
                    Text(entry.isMuted ? "静音 · \(entry.volume)%" : "音量 · \(entry.volume)%")
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Image(systemName: entry.audioSymbol)
                    Text(entry.outputName)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                volumeDots
            }
        }
        .padding(4)
    }

    private func glyph(size: CGFloat) -> some View {
        ZStack {
            DuoWidgetArc(progress: 1)
                .stroke(.primary.opacity(0.14), style: StrokeStyle(lineWidth: max(3, size * 0.075), lineCap: .round))
            DuoWidgetArc(progress: CGFloat(entry.battery) / 100)
                .stroke(batteryTint, style: StrokeStyle(lineWidth: max(3, size * 0.075), lineCap: .round))
            Image(systemName: entry.network.symbol)
                .font(.system(size: size * 0.22, weight: .medium))
                .foregroundStyle(entry.network == .offline ? .red : .primary)
            HStack(spacing: max(2, size * 0.055)) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(dotColor(for: index))
                        .frame(width: max(3, size * 0.075), height: max(3, size * 0.075))
                }
            }
            .offset(y: size * 0.30)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("電量 \(entry.battery)%，\(entry.network.label)，\(entry.isMuted ? "靜音" : "音量 \(entry.volume)%")")
    }

    private var volumeDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { index in
                Circle().fill(dotColor(for: index)).frame(width: 5, height: 5)
            }
            Text(entry.isMuted ? "靜音" : "\(entry.volume)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text(entry.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func dotColor(for index: Int) -> Color {
        guard !entry.isMuted else { return .gray.opacity(0.65) }
        let active = entry.volume == 0 ? 0 : min(4, max(1, Int(ceil(Double(entry.volume) / 25))))
        return index < active ? .primary : .primary.opacity(0.2)
    }
}

@main
struct DuoStatusWidget: Widget {
    let kind = "DuoStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DuoWidgetProvider()) { entry in
            DuoWidgetView(entry: entry)
        }
        .configurationDisplayName("Duo 状态")
        .description("查看 Mac 电量、网络和音量状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
