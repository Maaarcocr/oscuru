import Darwin
import Foundation
import Network
import Observation
import OscuruEngine
import UIKit
import os

/// What the app is doing, for seeing why things are slow or stuck: the connection, how hard the
/// processor and memory are worked, what each assistant is doing and for how long, what the
/// engine is drawing or waiting for, and a log of what happened lately. Shown in Settings →
/// Diagnostics, and shared from there as a report. Words here are for the developer, in English.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()

    struct Event: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// The latest events, newest last.
    private(set) var events: [Event] = []
    /// How the phone is connected: "Wi-Fi", "cellular", "none", and whether the system calls it expensive or constrained.
    private(set) var network = "unknown"

    private static let kept = 400
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// The interfaces the phone reaches the internet through, to notice them changing.
    @ObservationIgnored private var route: String?
    @ObservationIgnored private let launched = Date()

    private init() {
        monitor.pathUpdateHandler = { path in
            let described = Diagnostics.describe(path)
            let route = Diagnostics.route(path)
            let reachable = path.status == .satisfied
            Task { @MainActor in
                let shared = Diagnostics.shared
                // A different way out (or none, or back) can leave requests on a dead connection.
                if shared.route != route {
                    if shared.route != nil {
                        Connection.networkChanged(reachable: reachable)
                        shared.log("Network changed: requests under way must show they are alive within a few seconds, or are sent again")
                    }
                    shared.route = route
                }
                guard shared.network != described else { return }
                shared.network = described
                shared.log("Network: \(described)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "oscuru.diagnostics.network"))
        let center = NotificationCenter.default
        let notes: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "App left the screen"),
            (UIApplication.willEnterForegroundNotification, "App back on screen"),
            (UIApplication.didReceiveMemoryWarningNotification, "Memory warning from iOS"),
            (ProcessInfo.thermalStateDidChangeNotification, "Heat changed"),
        ]
        for (name, text) in notes {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let shared = Diagnostics.shared
                    shared.log(name == ProcessInfo.thermalStateDidChangeNotification ? "\(text): \(Diagnostics.heat)" : text)
                }
            }
        }
        // Back on screen: requests waiting to be sent again go now.
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Wakeups.wake() }
        }
        log("App started")
    }

    /// Notes something that happened.
    func log(_ text: String) {
        events.append(Event(date: Date(), text: text))
        if events.count > Diagnostics.kept { events.removeFirst(events.count - Diagnostics.kept) }
    }

    nonisolated private static func route(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        return path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).joined(separator: ",")
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return path.status == .requiresConnection ? "waiting for a connection" : "none" }
        var kinds: [String] = []
        if path.usesInterfaceType(.wifi) { kinds.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { kinds.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { kinds.append("wired") }
        if kinds.isEmpty { kinds.append("other") }
        if path.isExpensive { kinds.append("expensive") }
        if path.isConstrained { kinds.append("Low Data Mode") }
        return kinds.joined(separator: ", ")
    }

    // MARK: The process

    /// How busy the processor is with the app: the sum of its threads' use, in cores (2.5 is two
    /// and a half cores flat out), and how many the phone has.
    static var cores: (busy: Double, of: Int) {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return (0, ProcessInfo.processInfo.activeProcessorCount) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
        }
        return (total, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// The memory the app holds, and how much more iOS would let it have before ending it, in megabytes.
    static var memory: (used: Double, left: Double) {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        let used = result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        return (used, Double(os_proc_available_memory()) / 1_048_576)
    }

    static var heat: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot (iOS is slowing the phone)"
        case .critical: return "critical (iOS is slowing the phone hard)"
        @unknown default: return "unknown"
        }
    }

    // MARK: What is going on

    /// One line for something that has gone on since `date`: "12s", "3m 05s".
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s" : String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    struct Line: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    /// The state of the app now, as lines.
    func now(model: AppModel) -> [Line] {
        let cores = Diagnostics.cores
        let memory = Diagnostics.memory
        let app = UIApplication.shared.applicationState
        return [
            Line(id: "network", title: "Network", detail: network),
            Line(id: "app", title: "App", detail: app == .active ? "on screen" : app == .background ? "in the background" : "leaving or returning"),
            Line(id: "drawing", title: "Drawing", detail: model.engine.isInBackground ? "waits until the app is back on screen" : "on the graphics processor"),
            Line(id: "cpu", title: "Processor", detail: String(format: "%.1f of %d cores busy", cores.busy, cores.of)),
            Line(id: "memory", title: "Memory", detail: String(format: "%.0f MB used, %.0f MB more allowed", memory.used, memory.left)),
            Line(id: "heat", title: "Heat", detail: Diagnostics.heat),
            Line(id: "power", title: "Low Power Mode", detail: ProcessInfo.processInfo.isLowPowerModeEnabled ? "on (iOS is slowing the phone)" : "off"),
            Line(id: "uptime", title: "Running for", detail: Diagnostics.elapsed(since: launched)),
        ]
    }

    /// What each photo's assistant is doing.
    func assistants(model: AppModel) -> [Line] {
        model.openEditors.sorted { $0.document.fileName < $1.document.fileName }.map { editor in
            Line(id: editor.document.id, title: editor.document.fileName, detail: editor.diagnosis)
        }
    }

    /// What the engine is doing and waiting to do, and how much each photo has queued.
    func engine(model: AppModel) -> [Line] {
        let now = Date()
        var lines = model.engine.activity.map { activity in
            Line(
                id: activity.id.uuidString, title: name(of: activity.photo, model: model),
                detail: "\(activity.what) — \(describe(activity.state)) for \(Diagnostics.elapsed(since: activity.since, now: now))"
                    + (activity.state == .working ? "" : " (asked \(Diagnostics.elapsed(since: activity.asked, now: now)) ago)") + (activity.large ? ", full size" : ""))
        }
        for (lane, count) in Rendering.queued.sorted(by: { $0.key < $1.key }) where count > 0 {
            lines.append(Line(id: "lane-\(lane)", title: name(of: lane, model: model), detail: "\(count) waiting or drawing in its queue"))
        }
        return lines
    }

    /// Engine work that took a while lately, newest first.
    func slow(model: AppModel) -> [Line] {
        model.engine.recentActivity.filter { ($0.seconds ?? 0) >= 1 }.prefix(20).map { activity in
            Line(
                id: activity.id.uuidString, title: name(of: activity.photo, model: model),
                detail: String(format: "%@ took %.1fs%@ — %@", activity.what, activity.seconds ?? 0, activity.failed ? " and failed" : "",
                    activity.asked.formatted(date: .omitted, time: .standard)))
        }
    }

    private func describe(_ state: Engine.Activity.State) -> String {
        switch state {
        case .waitingForPhoto: return "waiting for this photo's other drawing"
        case .waitingForLarge: return "waiting for another photo's full-size work"
        case .waitingForScreen: return "waiting for the app to be back on screen"
        case .working: return "working"
        }
    }

    /// A photo's name from an engine or queue id, which starts with the photo's id.
    private func name(of id: String, model: AppModel) -> String {
        model.library.photos.first { id.hasPrefix($0.id) }?.fileName ?? id
    }

    /// Everything above and the log, as text to send.
    func report(model: AppModel) -> String {
        let bundle = Bundle.main.infoDictionary ?? [:]
        let version = "\(bundle["CFBundleShortVersionString"] as? String ?? "?") (\(bundle["CFBundleVersion"] as? String ?? "?"))"
        var text = "Oscuru diagnostics, \(Date().formatted(date: .abbreviated, time: .standard))\nVersion \(version), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n"
        func section(_ title: String, _ lines: [Line]) {
            text += "\n\(title)\n"
            if lines.isEmpty { text += "  (nothing)\n" }
            for line in lines { text += "  \(line.title): \(line.detail)\n" }
        }
        section("Now", now(model: model))
        section("Assistants", assistants(model: model))
        section("Engine", engine(model: model))
        section("Slow engine work", slow(model: model))
        text += "\nLog\n"
        for event in events { text += "  \(event.date.formatted(date: .omitted, time: .standard))  \(event.text)\n" }
        return text
    }

    /// The report as a file for the share sheet.
    func reportFile(model: AppModel) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Diagnostics \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Oscuru diagnostics \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).txt")
        try Data(report(model: model).utf8).write(to: file)
        return file
    }
}
