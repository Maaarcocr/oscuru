import AVFoundation
import Foundation
import Observation
import OscuruCore
import UIKit

/// A lens the camera can shoot RAW with, labelled the way the Camera app labels it ("0.5", "1", "3"),
/// and the ways it can shoot.
struct Lens: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let zoom: Double
    /// Single-frame Bayer RAW.
    var bayer = true
    /// Apple ProRAW.
    var proRAW = false
}

/// A value of the camera the person can set by hand, or leave to the camera.
enum CameraValue: String, CaseIterable, Identifiable, Sendable {
    case aperture, time, iso, focus
    /// How many RAW frames are averaged into the shot: one, unless the person asks for more.
    case frames

    var id: String { rawValue }
}

/// How the camera shoots, as the person chooses.
enum ShootingMode: String, Sendable {
    /// Single-frame Bayer RAW: the sensor's data with nothing done to it, each lens at its own zoom.
    case zero
    /// Apple ProRAW: a linear DNG Apple has already merged and cleaned, at the sensor's full size,
    /// so a shot can be framed at any zoom between the lenses.
    case proRAW
}

/// The camera: RAW from one lens at a time, and nothing else. In zero processing (the default) it
/// is single-frame Bayer RAW: Smart HDR, Deep Fusion, night mode and multi-frame merging only ever
/// touch processed photos, and Oscuru asks for the sensor data alone, so none of them run. In
/// ProRAW it is Apple's processed RAW at full size, and the viewfinder zooms anywhere between the
/// lenses: the shot is the lens's whole frame, and the zoom is the crop the photo starts with.
/// Each shot is kept as a DNG and goes into the library as an untouched original.
///
/// The exposure is the photographer's: aperture (where the lens has one), time and ISO are each
/// left to the camera or set by hand, and whatever is set is what is shot. Focus likewise.
///
/// Frames, a feature turned on in Settings, adds one more value in zero processing: at ×8 the
/// camera takes eight RAW frames at one exposure and they are lined up and averaged into one RAW
/// file (`BurstMerge`), for less noise. It is ×1 until the person turns it.
@MainActor
@Observable
final class Camera {
    enum Status: Equatable {
        case starting
        case ready
        /// The person said no to camera access.
        case denied
        /// No camera on this iPhone hands RAW sensor data to apps.
        case unavailable
    }

    private(set) var status: Status = .starting
    /// Every lens that can shoot RAW one way or the other.
    private(set) var lenses: [Lens] = []
    private(set) var lens: Lens?
    private(set) var mode: ShootingMode
    /// What the viewfinder shows, counted as the Camera app does (0.5, 1, 2.5, …). In zero processing,
    /// always a lens's own.
    private(set) var zoom: Double = 1
    /// The thirds grid and the level over the viewfinder. Kept between launches.
    private(set) var showsGuides = UserDefaults.standard.bool(forKey: Camera.guidesKey)
    /// What is set by hand of the exposure (a value left nil is the camera's), and the compensation
    /// for whatever is left to the camera.
    private(set) var exposure = ExposureSettings()
    /// The focus set by hand, as a lens position (0 its nearest, 1 its farthest); nil while the camera focuses.
    private(set) var focusSet: Double?
    /// What the lens in use lets a photographer set.
    private(set) var limits = ExposureLimits()
    /// What the camera is doing now.
    private(set) var reading = ExposureReading()
    /// The latest live frame as the instruments read it: its histogram and where it is blown.
    private(set) var statistics: FrameStatistics?
    /// How far the sensor's picture is turned to stand upright in the viewfinder, in degrees
    /// clockwise: what the instruments' map of the frame needs to lie over it.
    private(set) var frameRotation: Double = 90
    /// How many RAW frames a shot is averaged from.
    private(set) var frames = 1
    /// Whether Frames is turned on in Settings.
    private(set) var framesEnabled = UserDefaults.standard.bool(forKey: Camera.framesKey)
    /// While the frames of a shot are being taken: how many so far, of how many. The phone should be held still.
    private(set) var burst: (taken: Int, of: Int)?
    /// Goes up as each shot is taken, for the shutter blink and the haptic.
    private(set) var shots = 0
    /// Shots taken and not yet in the library.
    private(set) var saving = 0
    /// The latest photo this camera put in the library.
    private(set) var lastPhotoID: String?
    var problem: String?

    /// In UI tests (and the simulator there is no camera): a still picture stands in for the viewfinder.
    let simulated: Bool
    @ObservationIgnored let service = CaptureService()
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    /// Counts the exposures asked for, so an answer to an older one never undoes a newer one.
    @ObservationIgnored private var exposureChanges = 0
    @ObservationIgnored weak var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet { followRotation() }
    }

    init(library: Library, simulated: Bool) {
        self.library = library
        self.simulated = simulated
        mode = ShootingMode(rawValue: UserDefaults.standard.string(forKey: Camera.modeKey) ?? "") ?? .zero
    }

    static let exposureRange: ClosedRange<Float> = -3...3
    /// Whether Frames is turned on: Settings writes it, the camera reads it.
    static let framesKey = "camera.frames"
    static let frameCounts: [Double] = [1, 2, 4, 8, 16]
    private static let modeKey = "camera.mode"
    private static let guidesKey = "camera.guides"

    // MARK: Zoom

    var canShootProRAW: Bool { lenses.contains(where: \.proRAW) }

    /// The lenses that shoot the way the camera shoots now.
    var shootingLenses: [Lens] { lenses.filter { mode == .proRAW ? $0.proRAW : $0.bayer } }

    /// The lens the viewfinder's picture comes from: the one in use, once its picture has replaced
    /// the last lens's. Changing lenses takes the camera a moment.
    private(set) var previewLens: Lens?
    /// While the picture changes from one lens to another, which the viewfinder softens.
    private(set) var switchingLens = false
    @ObservationIgnored private var lensSwitches = 0

    /// How much closer than the picture it has the viewfinder is: the zoom over the lens that
    /// picture comes from, so a lens change never shows the last lens uncropped. 1 in zero processing.
    var magnification: Double { mode == .proRAW ? max(1, zoom / (previewLens?.zoom ?? lens?.zoom ?? zoom)) : 1 }

    /// How much closer than the lens in use a shot is framed: the crop it starts with.
    private var framingZoom: Double { mode == .proRAW ? max(1, zoom / (lens?.zoom ?? zoom)) : 1 }

    /// Changes the camera's lens (or mode) with `change`, then, once the new lens's first pictures
    /// have had time to arrive, lets the viewfinder frame them. A later change supersedes this one.
    private func switchLens(to next: Lens, _ change: @escaping @MainActor () async -> Void) {
        guard !simulated else {
            previewLens = next
            return
        }
        lensSwitches += 1
        let number = lensSwitches
        switchingLens = true
        Task {
            await change()
            followRotation()
            try? await Task.sleep(for: .milliseconds(250))
            guard number == lensSwitches else { return }
            previewLens = next
            switchingLens = false
        }
    }

    /// From the widest lens to twice the longest.
    var zoomRange: ClosedRange<Double> {
        let zooms = shootingLenses.map(\.zoom)
        let low = zooms.min() ?? 1
        return low...max(low, (zooms.max() ?? 1) * 2)
    }

    /// The zooms a tap goes to: each lens's own, and in ProRAW 2 when no lens is near it, as the
    /// Camera app offers.
    var stops: [Double] {
        var stops = shootingLenses.map(\.zoom)
        if mode == .proRAW, let longest = stops.max(), longest > 2.4, !stops.contains(where: { abs($0 - 2) < 0.4 }) { stops.append(2) }
        return stops.sorted()
    }

    func setGuides(_ shown: Bool) {
        showsGuides = shown
        UserDefaults.standard.set(shown, forKey: Camera.guidesKey)
    }

    /// A pinch lands on a stop when it comes close to one.
    func snapped(_ value: Double) -> Double {
        stops.first { abs($0 / value - 1) < 0.04 } ?? value
    }

    /// Zooms the viewfinder, changing to the longest lens that is no closer than `value`. In zero
    /// processing it goes to the nearest lens's own view.
    func setZoom(_ value: Double) {
        let usable = shootingLenses
        guard !usable.isEmpty else { return }
        var target = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        if mode == .zero, let nearest = usable.min(by: { abs($0.zoom - target) < abs($1.zoom - target) }) {
            target = nearest.zoom
        }
        zoom = target
        let next = usable.last { $0.zoom <= target * 1.001 } ?? usable[0]
        guard next != lens else { return }
        lens = next
        switchLens(to: next) { self.adopt(await self.service.use(lensID: next.id)) }
    }

    /// Changes how the camera shoots. The viewfinder goes back to a lens's own view: this one when
    /// it shoots that way too, otherwise the main lens.
    func setMode(_ mode: ShootingMode) {
        guard mode != self.mode, mode == .zero || canShootProRAW else { return }
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Camera.modeKey)
        applyMode()
    }

    private func applyMode() {
        let usable = shootingLenses
        let next = usable.first { $0 == lens } ?? usable.min { abs($0.zoom - 1) < abs($1.zoom - 1) }
        lens = next
        zoom = next?.zoom ?? 1
        guard let next else { return }
        let proRAW = mode == .proRAW
        switchLens(to: next) { self.adopt(await self.service.configure(proRAW: proRAW, lensID: next.id)) }
    }

    /// "0.5", "1", "2.5", "2.7": a zoom as the camera shows it.
    nonisolated static func zoomText(_ zoom: Double) -> String {
        let rounded = zoom < 0.8 ? 0.5 : (zoom * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: Starting and stopping

    func start() async {
        if simulated {
            lenses = [
                Lens(id: "0.5", label: "0.5", zoom: 0.5, proRAW: true), Lens(id: "1", label: "1", zoom: 1, proRAW: true),
                Lens(id: "3", label: "3", zoom: 3, proRAW: true),
            ]
            lens = lenses[1]
            previewLens = lenses[1]
            zoom = 1
            // A lens with an aperture to set, and a still picture for the instruments to read.
            limits = ExposureLimits(aperture: 1.5...4, apertureStops: [1.5, 2, 2.8, 4], time: (1.0 / 8000)...1, iso: 50...6400)
            reading = ExposureReading(aperture: 1.8, time: 1.0 / 125, iso: 80, offset: 0, focus: 0.7)
            frameRotation = 0
            status = .ready
            statistics = await Task.detached { UITesting.sampleStatistics() }.value
            return
        }
        if status == .ready {
            service.start()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .denied
                return
            }
        default:
            status = .denied
            return
        }
        service.onReading = { [weak self] reading in
            Task { @MainActor in self?.reading = reading }
        }
        service.onStatistics = { [weak self] statistics in
            Task { @MainActor in self?.statistics = statistics }
        }
        let (lenses, current, limits) = await service.configure()
        guard !lenses.isEmpty else {
            status = .unavailable
            return
        }
        self.lenses = lenses
        self.limits = limits
        lens = current
        previewLens = current
        zoom = current?.zoom ?? 1
        if mode == .proRAW, !canShootProRAW { mode = .zero }
        followRotation()
        status = .ready
        if mode == .proRAW { applyMode() }
        service.start()
    }

    func stop() {
        if !simulated { service.stop() }
    }

    // MARK: Controls

    /// Focuses and meters on a point of the viewfinder (in the preview layer's coordinates). A
    /// focus set by hand goes back to the camera.
    func focus(at layerPoint: CGPoint) {
        focusSet = nil
        guard !simulated, let previewLayer else { return }
        service.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }

    /// Exposure compensation, in stops.
    var exposureBias: Float { Float(exposure.bias) }

    func setExposureBias(_ bias: Float) {
        let clamped = min(max(bias, Self.exposureRange.lowerBound), Self.exposureRange.upperBound)
        // Third-stops, like a camera dial.
        let stepped = (clamped * 3).rounded() / 3
        guard stepped != exposureBias else { return }
        exposure.bias = Double(stepped)
        if !simulated { service.setExposureBias(stepped) }
    }

    /// Whether nothing of the exposure is left to the camera: compensation then has nothing to act
    /// on, and the meter says how far the picture is from what the camera would choose.
    var isManual: Bool { exposure.isManual(with: limits) }

    /// The values in the line under the viewfinder. Frames only where it is turned on, and only in
    /// zero processing: ProRAW is already Apple's merging of frames.
    var values: [CameraValue] { [.aperture, .time, .iso, .focus] + (framesEnabled && mode == .zero ? [.frames] : []) }

    func isSet(_ value: CameraValue) -> Bool {
        switch value {
        case .aperture: return exposure.aperture != nil
        case .time: return exposure.time != nil
        case .iso: return exposure.iso != nil
        case .focus: return focusSet != nil
        case .frames: return frames > 1
        }
    }

    /// Whether this lens lets the value be set at all: most have one aperture.
    func canSet(_ value: CameraValue) -> Bool {
        switch value {
        case .aperture: return !limits.apertureIsFixed
        case .time, .iso, .frames: return true
        case .focus: return limits.focus
        }
    }

    /// The value as it is now: what is set, or else what the camera is doing.
    func shown(_ value: CameraValue) -> Double {
        switch value {
        case .aperture: return exposure.aperture ?? reading.aperture
        case .time: return exposure.time ?? reading.time
        case .iso: return exposure.iso ?? reading.iso
        case .focus: return focusSet ?? reading.focus
        case .frames: return Double(frames)
        }
    }

    /// The values its dial stops at, smallest first. Focus has none: it turns smoothly.
    func stops(_ value: CameraValue) -> [Double] {
        switch value {
        case .aperture: return limits.apertures
        case .time: return limits.times
        case .iso: return limits.isos
        case .focus: return []
        case .frames: return Self.frameCounts
        }
    }

    /// Sets a value by hand, at the stop nearest `amount`; nil hands it back to the camera.
    func set(_ value: CameraValue, to amount: Double?) {
        if value == .focus {
            let position = amount.map { min(max($0, 0), 1) }
            guard position != focusSet else { return }
            focusSet = position
            if !simulated { service.setFocus(position) }
            return
        }
        if value == .frames {
            let count = Int(ExposureScale.nearest(amount ?? 1, in: Self.frameCounts))
            if count != frames { frames = count }
            return
        }
        guard canSet(value) || amount == nil else { return }
        var next = exposure
        let stop = amount.map { ExposureScale.nearest($0, in: stops(value)) }
        switch value {
        case .aperture: next.aperture = stop
        case .time: next.time = stop
        case .iso: next.iso = stop
        case .focus, .frames: break
        }
        guard next != exposure else { return }
        exposure = next
        guard !simulated else { return }
        exposureChanges += 1
        let change = exposureChanges
        Task {
            // Where this lens cannot leave the rest to the camera beside what is set, it holds the
            // rest where it is, and that shows as set; handing a value back then hands back all.
            var applied = await service.apply(next, holding: amount != nil)
            applied.bias = exposure.bias
            if change == exposureChanges, applied != exposure { exposure = applied }
        }
    }

    /// One stop of its dial up or down, for VoiceOver.
    func step(_ value: CameraValue, by count: Int) {
        if value == .focus {
            set(.focus, to: shown(.focus) + Double(count) * 0.05)
        } else {
            set(value, to: ExposureScale.step(shown(value), by: count, in: stops(value)))
        }
    }

    /// After a change of lens or of mode: what the new lens allows, and the exposure as it took it.
    private func adopt(_ state: LensState) {
        limits = state.limits
        exposureChanges += 1
        var taken = state.exposure
        taken.bias = exposure.bias
        if taken != exposure { exposure = taken }
        focusSet = nil
    }

    /// Takes a picture and puts it in the library. Several can be on their way at once, but the
    /// frames of one shot are taken before the next shot starts.
    func shoot() {
        guard status == .ready, burst == nil else { return }
        // What the viewfinder showed beyond the lens becomes the crop the photo starts with.
        let framing = framingZoom > 1.001 ? Crop.centered(zoom: framingZoom) : nil
        let proRAW = mode == .proRAW
        let count = values.contains(.frames) ? frames : 1
        saving += 1
        Task {
            defer { saving -= 1 }
            do {
                let file: URL
                /// How many frames the file was averaged from, and one of them as taken, kept in
                /// case the averaged file cannot be opened.
                var averaged: Int?
                var spare: Data?
                if simulated {
                    shots += 1
                    guard let sample = UITesting.samplePhoto() else { throw CameraError.noRAW }
                    file = sample
                } else {
                    let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
                    let data: Data
                    if count > 1 {
                        burst = (0, count)
                        let taken: [Data]
                        do {
                            taken = try await service.captureBurst(count: count, rotationAngle: angle) { done in
                                Task { @MainActor in if self.burst != nil { self.burst = (done, count) } }
                            }
                        } catch {
                            burst = nil
                            throw error
                        }
                        burst = nil
                        // The blink and the tap in the hand that say the phone can move again.
                        shots += 1
                        do {
                            let merged = try await Task.detached(priority: .userInitiated) { try Camera.merge(taken) }.value
                            data = merged.data
                            if merged.frames > 1 {
                                averaged = merged.frames
                                spare = taken[0]
                            }
                        } catch {
                            // Frames that cannot be averaged are still a photo: the first of them.
                            data = taken[0]
                            problem = L10n.cameraFramesFailed
                        }
                    } else {
                        data = try await service.capture(rotationAngle: angle, proRAW: proRAW) {
                            Task { @MainActor in self.shots += 1 }
                        }
                    }
                    file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).dng")
                    try data.write(to: file)
                }
                defer { try? FileManager.default.removeItem(at: file) }
                // Named for when it was taken; the extension keeps a time like "15.04" whole in titles.
                let name = "\(Date.now.formatted(.dateTime.day().month(.abbreviated).hour().minute())).\(file.pathExtension)"
                let document: PhotoDocument
                do {
                    document = try await library.add(from: file, name: name, framing: framing, frames: averaged)
                } catch {
                    guard let spare else { throw error }
                    try spare.write(to: file)
                    document = try await library.add(from: file, name: name, framing: framing)
                    problem = L10n.cameraFramesFailed
                }
                lastPhotoID = document.id
            } catch {
                problem = (error as? CameraError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Averages the frames of one shot into one DNG: the sharpest of the first three is the
    /// picture, and the others are lined up with it and averaged in (`BurstMerge`). The file is
    /// that frame's own, with the averaged samples in place of its own.
    nonisolated static func merge(_ files: [Data]) throws -> (data: Data, frames: Int) {
        guard files.count > 1 else { return (files[0], 1) }
        let first = try files.prefix(3).map { try DNG.frame(of: $0) }
        let sharpness = first.map { BurstMerge.sharpness(of: $0) }
        let sharpest = sharpness.indices.max { sharpness[$0] < sharpness[$1] } ?? 0
        var merge = BurstMerge(reference: first[sharpest])
        for (index, frame) in first.enumerated() where index != sharpest { merge.add(frame) }
        for file in files.dropFirst(3) { merge.add(try DNG.frame(of: file)) }
        return (try DNG.replacingFrame(of: files[sharpest], with: merge.merged()), merge.frames)
    }

    /// Keeps the viewfinder upright and records which way the phone was held in each shot.
    private func followRotation() {
        guard !simulated, let previewLayer, let device = service.currentDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        frameRotation = Double(coordinator.videoRotationAngleForHorizonLevelPreview)
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(coordinator.videoRotationAngleForHorizonLevelPreview) {
            connection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        }
    }
}

enum CameraError: Error {
    /// The lens in use did not offer Bayer RAW.
    case noRAW
    case noPhoto

    var message: String {
        switch self {
        case .noRAW: return L10n.cameraNoRAW
        case .noPhoto: return L10n.cameraFailed
        }
    }
}
