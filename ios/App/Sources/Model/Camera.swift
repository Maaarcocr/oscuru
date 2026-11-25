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
    /// Exposure compensation, in stops.
    private(set) var exposureBias: Float = 0
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
    @ObservationIgnored weak var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet { followRotation() }
    }

    init(library: Library, simulated: Bool) {
        self.library = library
        self.simulated = simulated
        mode = ShootingMode(rawValue: UserDefaults.standard.string(forKey: Camera.modeKey) ?? "") ?? .zero
    }

    static let exposureRange: ClosedRange<Float> = -3...3
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
        let bias = exposureBias
        switchLens(to: next) { await self.service.use(lensID: next.id, exposureBias: bias) }
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
        let bias = exposureBias
        switchLens(to: next) { await self.service.configure(proRAW: proRAW, lensID: next.id, exposureBias: bias) }
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
            status = .ready
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
        let (lenses, current) = await service.configure()
        guard !lenses.isEmpty else {
            status = .unavailable
            return
        }
        self.lenses = lenses
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

    /// Focuses and meters on a point of the viewfinder (in the preview layer's coordinates).
    func focus(at layerPoint: CGPoint) {
        guard !simulated, let previewLayer else { return }
        service.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }

    func setExposureBias(_ bias: Float) {
        let clamped = min(max(bias, Self.exposureRange.lowerBound), Self.exposureRange.upperBound)
        // Third-stops, like a camera dial.
        let stepped = (clamped * 3).rounded() / 3
        guard stepped != exposureBias else { return }
        exposureBias = stepped
        if !simulated { service.setExposureBias(stepped) }
    }

    /// Takes a picture and puts it in the library. Several can be on their way at once.
    func shoot() {
        guard status == .ready else { return }
        // What the viewfinder showed beyond the lens becomes the crop the photo starts with.
        let framing = framingZoom > 1.001 ? Crop.centered(zoom: framingZoom) : nil
        let proRAW = mode == .proRAW
        saving += 1
        Task {
            defer { saving -= 1 }
            do {
                let file: URL
                if simulated {
                    shots += 1
                    guard let sample = UITesting.samplePhoto() else { throw CameraError.noRAW }
                    file = sample
                } else {
                    let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
                    let data = try await service.capture(rotationAngle: angle, proRAW: proRAW) {
                        Task { @MainActor in self.shots += 1 }
                    }
                    file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).dng")
                    try data.write(to: file)
                }
                defer { try? FileManager.default.removeItem(at: file) }
                // Named for when it was taken; the extension keeps a time like "15.04" whole in titles.
                let name = "\(Date.now.formatted(.dateTime.day().month(.abbreviated).hour().minute())).\(file.pathExtension)"
                let document = try await library.add(from: file, name: name, framing: framing)
                lastPhotoID = document.id
            } catch {
                problem = (error as? CameraError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Keeps the viewfinder upright and records which way the phone was held in each shot.
    private func followRotation() {
        guard !simulated, let previewLayer, let device = service.currentDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
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

/// The capture session and everything that touches it, on one queue of its own.
final class CaptureService: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "oscuru.camera")
    private var input: AVCaptureDeviceInput?
    private var devices: [String: AVCaptureDevice] = [:]
    /// Each capture's delegate, kept alive until its photo has been delivered.
    private var inFlight: [Int64: PhotoCapture] = [:]
    /// Whether shots are ProRAW rather than Bayer RAW. Read and changed on the queue.
    private var proRAW = false
    private let lock = NSLock()
    private var device: AVCaptureDevice?

    var currentDevice: AVCaptureDevice? { lock.withLock { device } }

    /// Sets up the session and finds the back lenses that can shoot Bayer RAW or ProRAW, widest
    /// first. Starts on the main lens, shooting Bayer RAW.
    func configure() async -> ([Lens], Lens?) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.configureNow()) }
        }
    }

    private func configureNow() -> ([Lens], Lens?) {
        let all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back
        ).devices
        guard let main = all.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? all.first else { return ([], nil) }

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // Bayer RAW is only offered while ProRAW is off.
        output.isAppleProRAWEnabled = false

        let mainField = Self.fieldOfView(main)
        var lenses: [Lens] = []
        for device in all {
            guard use(device) else { continue }
            let bayer = bayerFormat != nil
            let proRAW = output.isAppleProRAWSupported
            guard bayer || proRAW else { continue }
            devices[device.uniqueID] = device
            let zoom = tan(mainField / 2) / tan(Self.fieldOfView(device) / 2)
            lenses.append(Lens(id: device.uniqueID, label: Self.label(zoom: zoom), zoom: zoom, bayer: bayer, proRAW: proRAW))
        }
        if lenses.isEmpty {
            // Some iPhones only list RAW formats once the session runs: offer the main lens, and
            // say so at the shutter if it really has none.
            devices[main.uniqueID] = main
            lenses = [Lens(id: main.uniqueID, label: "1", zoom: 1)]
        }
        lenses.sort { $0.zoom < $1.zoom }
        let start = lenses.first { $0.id == main.uniqueID } ?? lenses[0]
        if let device = devices[start.id] { _ = use(device) }
        return (lenses, start)
    }

    /// Makes this device the session's camera. Call on the queue.
    @discardableResult
    private func use(_ device: AVCaptureDevice) -> Bool {
        if input?.device == device { return true }
        guard let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input, session.canAddInput(input) { session.addInput(input) }
            return false
        }
        session.addInput(newInput)
        input = newInput
        lock.withLock { self.device = device }
        return true
    }

    private var bayerFormat: OSType? {
        output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    func use(lensID: String, exposureBias: Float) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let device = self.devices[lensID] {
                    self.use(device)
                    self.prepareOutput()
                    self.applyExposureBias(exposureBias)
                }
                continuation.resume()
            }
        }
    }

    /// Switches between Bayer RAW and ProRAW, on this lens.
    func configure(proRAW: Bool, lensID: String, exposureBias: Float) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.proRAW = proRAW
                if let device = self.devices[lensID] { self.use(device) }
                self.prepareOutput()
                self.applyExposureBias(exposureBias)
                continuation.resume()
            }
        }
    }

    /// After a change of lens or of mode: ProRAW at the lens's largest size and best quality, or
    /// Bayer RAW (only offered while ProRAW is off). Call on the queue.
    private func prepareOutput() {
        let on = proRAW && output.isAppleProRAWSupported
        if output.isAppleProRAWEnabled != on { output.isAppleProRAWEnabled = on }
        guard on, let device = input?.device else { return }
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            output.maxPhotoDimensions = largest
        }
        if output.maxPhotoQualityPrioritization != .quality { output.maxPhotoQualityPrioritization = .quality }
    }

    func start() {
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Focuses and meters on a point in device coordinates (0...1, landscape, home button right).
    func focus(at point: CGPoint) {
        queue.async {
            guard let device = self.input?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    func setExposureBias(_ bias: Float) {
        queue.async { self.applyExposureBias(bias) }
    }

    private func applyExposureBias(_ bias: Float) {
        guard let device = input?.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
    }

    /// Takes one RAW photo (Bayer, or ProRAW when `proRAW` and the lens offers it) and returns it as
    /// DNG data. `didCapture` runs when the sensor has been read, which is when the shutter should
    /// look and feel taken.
    func capture(rotationAngle: CGFloat, proRAW: Bool, didCapture: @escaping @Sendable () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let useProRAW = proRAW && self.output.isAppleProRAWEnabled
                let format =
                    useProRAW
                    ? self.output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } : self.bayerFormat
                guard let format else {
                    continuation.resume(throwing: CameraError.noRAW)
                    return
                }
                // RAW only: no processed image is asked for. In zero processing none of Apple's
                // processing runs; quality prioritization, stabilization, depth and distortion
                // correction only apply to processed photos and are left alone. ProRAW is Apple's
                // processing by nature: asked for at the lens's full size and best quality.
                let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
                if useProRAW {
                    settings.maxPhotoDimensions = self.output.maxPhotoDimensions
                    if self.output.maxPhotoQualityPrioritization == .quality { settings.photoQualityPrioritization = .quality }
                }
                if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                let id = settings.uniqueID
                let delegate = PhotoCapture(didCapture: didCapture) { result in
                    self.queue.async { self.inFlight[id] = nil }
                    continuation.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// The widest field of view any of the device's formats has, in radians.
    private static func fieldOfView(_ device: AVCaptureDevice) -> Double {
        let degrees = device.formats.map(\.videoFieldOfView).max() ?? device.activeFormat.videoFieldOfView
        return Double(degrees) * .pi / 180
    }

    /// "0.5", "1", "2", "3", "5": the zoom rounded the way the Camera app shows it.
    static func label(zoom: Double) -> String {
        let rounded = zoom < 0.8 ? 0.5 : (zoom * 2).rounded() / 2
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let didCapture: @Sendable () -> Void
    private let completion: (Result<Data, Error>) -> Void
    private var data: Data?
    private var failure: Error?

    init(didCapture: @escaping @Sendable () -> Void, completion: @escaping (Result<Data, Error>) -> Void) {
        self.didCapture = didCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        didCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            failure = error
        } else if photo.isRawPhoto {
            data = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let data {
            completion(.success(data))
        } else {
            completion(.failure(error ?? failure ?? CameraError.noPhoto))
        }
    }
}
