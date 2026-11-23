import AVFoundation
import Foundation
import Observation
import UIKit

/// A lens the camera can shoot RAW with, labelled the way the Camera app labels it ("0.5", "1", "3").
struct Lens: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let zoom: Double
}

/// The camera: single-frame Bayer RAW from one lens at a time, and nothing else. Smart HDR,
/// Deep Fusion, night mode and multi-frame merging only ever touch processed photos; Oscuru asks
/// for the sensor data alone, so none of them run. Each shot is kept as a DNG and goes into the
/// library as an untouched original, ready for the assistant.
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
    private(set) var lenses: [Lens] = []
    private(set) var lens: Lens?
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
    }

    static let exposureRange: ClosedRange<Float> = -3...3

    // MARK: Starting and stopping

    func start() async {
        if simulated {
            lenses = [Lens(id: "0.5", label: "0.5", zoom: 0.5), Lens(id: "1", label: "1", zoom: 1), Lens(id: "3", label: "3", zoom: 3)]
            lens = lenses[1]
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
        followRotation()
        status = .ready
        service.start()
    }

    func stop() {
        if !simulated { service.stop() }
    }

    // MARK: Controls

    func select(_ lens: Lens) {
        guard lens != self.lens else { return }
        self.lens = lens
        guard !simulated else { return }
        let bias = exposureBias
        Task {
            await service.use(lensID: lens.id, exposureBias: bias)
            followRotation()
        }
    }

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
                    let data = try await service.capture(rotationAngle: angle) {
                        Task { @MainActor in self.shots += 1 }
                    }
                    file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).dng")
                    try data.write(to: file)
                }
                defer { try? FileManager.default.removeItem(at: file) }
                // Named for when it was taken; the extension keeps a time like "15.04" whole in titles.
                let name = "\(Date.now.formatted(.dateTime.day().month(.abbreviated).hour().minute())).\(file.pathExtension)"
                let document = try await library.add(from: file, name: name)
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
    private let lock = NSLock()
    private var device: AVCaptureDevice?

    var currentDevice: AVCaptureDevice? { lock.withLock { device } }

    /// Sets up the session and finds the back lenses that can shoot Bayer RAW, widest first.
    /// Starts on the main lens.
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
            guard use(device), bayerFormat != nil else { continue }
            devices[device.uniqueID] = device
            let zoom = tan(mainField / 2) / tan(Self.fieldOfView(device) / 2)
            lenses.append(Lens(id: device.uniqueID, label: Self.label(zoom: zoom), zoom: zoom))
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
                    self.applyExposureBias(exposureBias)
                }
                continuation.resume()
            }
        }
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

    /// Takes one Bayer RAW photo and returns it as DNG data. `didCapture` runs when the sensor has
    /// been read, which is when the shutter should look and feel taken.
    func capture(rotationAngle: CGFloat, didCapture: @escaping @Sendable () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let format = self.bayerFormat else {
                    continuation.resume(throwing: CameraError.noRAW)
                    return
                }
                // RAW only: no processed image is asked for, so none of Apple's processing runs.
                // Quality prioritization, stabilization, depth and distortion correction only apply
                // to processed photos and are left alone.
                let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
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
