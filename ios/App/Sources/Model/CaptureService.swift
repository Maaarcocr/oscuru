import AVFoundation
import Foundation
import OscuruCore

/// What a change of lens or of mode leaves the camera with.
struct LensState: Sendable {
    var limits = ExposureLimits()
    /// The exposure in force: what was set, as far as the new lens can take it.
    var exposure = ExposureSettings()
}

/// The capture session and everything that touches it, on one queue of its own.
final class CaptureService: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    /// The live frames the instruments read: the histogram and the blown-highlight marks.
    private let frames = AVCaptureVideoDataOutput()
    private let meter = FrameMeter()
    private let queue = DispatchQueue(label: "oscuru.camera")
    private let meterQueue = DispatchQueue(label: "oscuru.camera.meter", qos: .utility)
    private var input: AVCaptureDeviceInput?
    private var devices: [String: AVCaptureDevice] = [:]
    /// Each capture's delegate, kept alive until its photo has been delivered.
    private var inFlight: [Int64: PhotoCapture] = [:]
    /// Whether shots are ProRAW rather than Bayer RAW. Read and changed on the queue.
    private var proRAW = false
    /// The exposure and the focus asked for, kept to set them again on another lens. On the queue.
    private var exposure = ExposureSettings()
    private var focusPosition: Double?
    private var readings: DispatchSourceTimer?
    private var lastReading: ExposureReading?
    private let lock = NSLock()
    private var device: AVCaptureDevice?

    var currentDevice: AVCaptureDevice? { lock.withLock { device } }

    /// What the camera is doing, several times a second while it runs. Set before `configure`.
    var onReading: (@Sendable (ExposureReading) -> Void)?
    /// What the instruments measured in a live frame. Set before `configure`.
    var onStatistics: (@Sendable (FrameStatistics) -> Void)? {
        get { meter.report }
        set { meter.report = newValue }
    }

    /// Sets up the session and finds the back lenses that can shoot Bayer RAW or ProRAW, widest
    /// first. Starts on the main lens, shooting Bayer RAW.
    func configure() async -> ([Lens], Lens?, ExposureLimits) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.configureNow()) }
        }
    }

    private func configureNow() -> ([Lens], Lens?, ExposureLimits) {
        let all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back
        ).devices
        guard let main = all.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? all.first else { return ([], nil, ExposureLimits()) }

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
        attachMeter()
        return (lenses, start, input.map { Self.limits(of: $0.device) } ?? ExposureLimits())
    }

    /// Asks for the live frames the instruments read, unless that costs this lens its RAW formats:
    /// the photo comes first.
    private func attachMeter() {
        guard session.canAddOutput(frames) else { return }
        let bayer = bayerFormat != nil
        let proRAW = output.isAppleProRAWSupported
        frames.alwaysDiscardsLateVideoFrames = true
        let wanted = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        if frames.availableVideoPixelFormatTypes.contains(wanted) {
            frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: wanted]
        }
        frames.setSampleBufferDelegate(meter, queue: meterQueue)
        session.beginConfiguration()
        session.addOutput(frames)
        session.commitConfiguration()
        if (bayer && bayerFormat == nil) || (proRAW && !output.isAppleProRAWSupported) {
            session.beginConfiguration()
            session.removeOutput(frames)
            session.commitConfiguration()
        }
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

    /// Changes lens, carrying the exposure over as far as the new lens can take it. Focus goes back
    /// to the camera: one lens's focus position means nothing on another.
    func use(lensID: String) async -> LensState {
        await withCheckedContinuation { continuation in
            queue.async {
                if let device = self.devices[lensID] { self.use(device) }
                continuation.resume(returning: self.settle())
            }
        }
    }

    /// Switches between Bayer RAW and ProRAW, on this lens.
    func configure(proRAW: Bool, lensID: String) async -> LensState {
        await withCheckedContinuation { continuation in
            queue.async {
                self.proRAW = proRAW
                if let device = self.devices[lensID] { self.use(device) }
                continuation.resume(returning: self.settle())
            }
        }
    }

    /// After a change of lens or of mode. Call on the queue.
    private func settle() -> LensState {
        prepareOutput()
        focusPosition = nil
        applyFocus()
        let applied = applyNow(exposure, holding: true)
        return LensState(limits: input.map { Self.limits(of: $0.device) } ?? ExposureLimits(), exposure: applied)
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
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.startReadings()
        }
    }

    /// Reads what the camera is doing several times a second, until it stops. On the queue.
    private func startReadings() {
        guard readings == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.read() }
        timer.resume()
        readings = timer
    }

    func stop() {
        queue.async {
            self.readings?.cancel()
            self.readings = nil
            self.lastReading = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: Exposure

    /// What this lens lets a photographer set.
    private static func limits(of device: AVCaptureDevice) -> ExposureLimits {
        func range(_ low: Double, _ high: Double, or fallback: ClosedRange<Double>) -> ClosedRange<Double> {
            low.isFinite && high.isFinite && low > 0 && high >= low ? low...high : fallback
        }
        let format = device.activeFormat
        let fixed = Double(device.lensAperture)
        let none = ExposureLimits()
        return ExposureLimits(
            aperture: range(Double(format.minLensAperture), Double(format.maxLensAperture), or: range(fixed, fixed, or: none.aperture)),
            apertureStops: format.recommendedLensApertureStops.map { Double($0) },
            time: range(format.minExposureDuration.seconds, format.maxExposureDuration.seconds, or: none.time),
            iso: range(Double(format.minISO), Double(format.maxISO), or: none.iso), focus: device.isLockingFocusWithCustomLensPositionSupported)
    }

    /// Sets the exposure, and says what is then in force. `holding` is what to do when this lens
    /// cannot leave the rest to the camera beside what is set: true holds the rest where it is (so
    /// it comes back set), false hands everything back to the camera.
    func apply(_ exposure: ExposureSettings, holding: Bool) async -> ExposureSettings {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.applyNow(exposure, holding: holding)) }
        }
    }

    /// Call on the queue.
    private func applyNow(_ wanted: ExposureSettings, holding: Bool) -> ExposureSettings {
        guard let device = input?.device else { return wanted }
        let limits = Self.limits(of: device)
        var settings = wanted.clamped(to: limits)
        guard (try? device.lockForConfiguration()) != nil else { return settings }
        defer { device.unlockForConfiguration() }
        if !settings.isAutomatic, device.isExposureModeSupported(.custom) {
            let format = device.activeFormat
            var aperture = settings.aperture.map { min(max(Float($0), format.minLensAperture), format.maxLensAperture) } ?? AVCaptureDevice.autoLensAperture
            var duration = settings.time.map { Self.duration($0, in: format) } ?? AVCaptureDevice.autoExposureDuration
            var iso = settings.iso.map { min(max(Float($0), format.minISO), format.maxISO) } ?? AVCaptureDevice.autoISO
            if !format.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) {
                if holding {
                    if settings.aperture == nil {
                        aperture = AVCaptureDevice.currentLensAperture
                        if !limits.apertureIsFixed { settings.aperture = Double(device.lensAperture) }
                    }
                    if settings.time == nil {
                        duration = AVCaptureDevice.currentExposureDuration
                        settings.time = device.exposureDuration.seconds
                    }
                    if settings.iso == nil {
                        iso = AVCaptureDevice.currentISO
                        settings.iso = Double(device.iso)
                    }
                }
                if !holding || !format.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) {
                    settings = ExposureSettings(bias: settings.bias)
                }
            }
            if !settings.isAutomatic {
                device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: nil)
            }
        } else {
            settings = ExposureSettings(bias: settings.bias)
        }
        if settings.isAutomatic, device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.setExposureTargetBias(min(max(Float(settings.bias), device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
        exposure = settings
        return settings
    }

    /// A shutter time the format accepts.
    private static func duration(_ seconds: Double, in format: AVCaptureDevice.Format) -> CMTime {
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        return CMTimeMaximum(format.minExposureDuration, CMTimeMinimum(format.maxExposureDuration, time))
    }

    func setExposureBias(_ bias: Float) {
        queue.async {
            self.exposure.bias = Double(bias)
            guard let device = self.input?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
        }
    }

    /// Tells the camera what it is doing now, when that has changed. On the queue.
    private func read() {
        guard let device = input?.device, let onReading else { return }
        let time = device.exposureDuration.seconds
        guard time.isFinite, time > 0 else { return }
        // Rounded as shown, so a meter that only trembles is not news.
        let reading = ExposureReading(
            aperture: Double(device.lensAperture), time: time, iso: Double(device.iso.rounded()),
            offset: (Double(device.exposureTargetOffset) * 10).rounded() / 10, focus: (Double(device.lensPosition) * 100).rounded() / 100)
        guard reading != lastReading else { return }
        lastReading = reading
        onReading(reading)
    }

    // MARK: Focus

    /// Focuses and meters on a point in device coordinates (0...1, landscape, home button right).
    /// Focus goes back to the camera; an exposure set by hand stays as set, metered there.
    func focus(at point: CGPoint) {
        queue.async {
            guard let device = self.input?.device, (try? device.lockForConfiguration()) != nil else { return }
            self.focusPosition = nil
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            device.unlockForConfiguration()
            // Setting the exposure again is what makes the camera meter at the new point.
            _ = self.applyNow(self.exposure, holding: true)
        }
    }

    /// Holds the lens at a position (0 its nearest, 1 its farthest), or with nil lets the camera focus.
    func setFocus(_ position: Double?) {
        queue.async {
            self.focusPosition = position
            self.applyFocus()
        }
    }

    /// Call on the queue.
    private func applyFocus() {
        guard let device = input?.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if let focusPosition, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: Float(min(max(focusPosition, 0), 1)), completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    // MARK: Capture

    /// Takes one RAW photo (Bayer, or ProRAW when `proRAW` and the lens offers it) and returns it as
    /// DNG data. `didCapture` runs when the sensor has been read, which is when the shutter should
    /// look and feel taken.
    func capture(rotationAngle: CGFloat, proRAW: Bool, didCapture: @escaping @Sendable () -> Void) async throws -> Data {
        let photos = try await request(rotationAngle: rotationAngle, didCapture: didCapture) {
            let useProRAW = proRAW && self.output.isAppleProRAWEnabled
            let format =
                useProRAW
                ? self.output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } : self.bayerFormat
            guard let format else { throw CameraError.noRAW }
            // RAW only: no processed image is asked for. In zero processing none of Apple's
            // processing runs. ProRAW is Apple's processing by nature: asked for at the lens's
            // full size and best quality. With any of the exposure set by hand, the shot is
            // asked for at speed instead: at any other quality Apple may shoot at a time and an
            // ISO of its own, and what was set is what must be shot.
            let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            let setByHand = !self.exposure.isAutomatic
            if useProRAW {
                settings.maxPhotoDimensions = self.output.maxPhotoDimensions
                if !setByHand, self.output.maxPhotoQualityPrioritization == .quality { settings.photoQualityPrioritization = .quality }
            }
            if setByHand { settings.photoQualityPrioritization = .speed }
            return settings
        }
        guard let photo = photos.first else { throw CameraError.noPhoto }
        return photo
    }

    /// Takes `count` Bayer RAW frames one after another, at the exposure and the focus the camera
    /// has when it starts, and returns each as DNG data in the order taken: the frames of one
    /// picture, to be averaged. `progress` says how many have been taken so far.
    func captureBurst(count: Int, rotationAngle: CGFloat, progress: @escaping @Sendable (Int) -> Void) async throws -> [Data] {
        await hold(true)
        var frames: [Data] = []
        do {
            while frames.count < count {
                let wanted = count - frames.count
                frames += try await request(rotationAngle: rotationAngle, didCapture: {}) {
                    guard let format = self.bayerFormat else { throw CameraError.noRAW }
                    // As many at once as the camera takes in one go, back to back; where it takes
                    // only one, one. The exposure is the camera's own, which is held for the burst.
                    let most = min(wanted, self.output.maxBracketedCapturePhotoCount)
                    guard most >= 2 else {
                        let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
                        settings.photoQualityPrioritization = .speed
                        return settings
                    }
                    let each = (0..<most).map { _ in
                        AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                            exposureDuration: AVCaptureDevice.currentExposureDuration, iso: AVCaptureDevice.currentISO)
                    }
                    let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: format, processedFormat: nil, bracketedSettings: each)
                    settings.photoQualityPrioritization = .speed
                    if self.output.isLensStabilizationDuringBracketedCaptureSupported { settings.isLensStabilizationEnabled = true }
                    return settings
                }
                progress(frames.count)
            }
        } catch {
            await hold(false)
            // What was taken before something went wrong is still a picture.
            if frames.isEmpty { throw error }
            return frames
        }
        await hold(false)
        return frames
    }

    /// Holds the exposure and the focus where they are for a burst, or gives them back to what
    /// was set (or to the camera) after it.
    private func hold(_ held: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if held, let device = self.input?.device, (try? device.lockForConfiguration()) != nil {
                    if device.isExposureModeSupported(.custom) {
                        device.setExposureModeCustom(
                            lensAperture: AVCaptureDevice.currentLensAperture, duration: AVCaptureDevice.currentExposureDuration,
                            iso: AVCaptureDevice.currentISO, completionHandler: nil)
                    }
                    if self.focusPosition == nil, device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    device.unlockForConfiguration()
                } else if !held {
                    _ = self.applyNow(self.exposure, holding: true)
                    self.applyFocus()
                }
                continuation.resume()
            }
        }
    }

    /// One capture request: `settings` makes it (on the queue), and every photo it gives comes
    /// back as DNG data, in order.
    private func request(
        rotationAngle: CGFloat, didCapture: @escaping @Sendable () -> Void, settings: @escaping @Sendable () throws -> AVCapturePhotoSettings
    ) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let made: AVCapturePhotoSettings
                do {
                    made = try settings()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                let id = made.uniqueID
                let delegate = PhotoCapture(didCapture: didCapture) { result in
                    self.queue.async { self.inFlight[id] = nil }
                    continuation.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.output.capturePhoto(with: made, delegate: delegate)
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

/// Measures a live frame for the instruments, a few times a second.
private final class FrameMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FrameStatistics) -> Void)?
    private var last: CFAbsoluteTime = 0

    var report: (@Sendable (FrameStatistics) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - last >= 0.12, let report, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, CVPixelBufferGetPlaneCount(buffer) == 2 else { return }
        last = now
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        report(
            FrameStatistics.measure(
                luma: UnsafeRawPointer(luma), lumaRowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chroma: UnsafeRawPointer(chroma),
                chromaRowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0), fullRange: fullRange))
    }
}

/// Collects the photos of one capture request: one, or the frames of a bracket.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private let didCapture: @Sendable () -> Void
    private let completion: (Result<[Data], Error>) -> Void
    /// Each photo's data by its place in the request.
    private var photos: [Int: Data] = [:]
    private var failure: Error?

    init(didCapture: @escaping @Sendable () -> Void, completion: @escaping (Result<[Data], Error>) -> Void) {
        self.didCapture = didCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        didCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            failure = error
        } else if photo.isRawPhoto, let data = photo.fileDataRepresentation() {
            photos[photo.photoCount] = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if photos.isEmpty {
            completion(.failure(error ?? failure ?? CameraError.noPhoto))
        } else {
            completion(.success(photos.keys.sorted().compactMap { photos[$0] }))
        }
    }
}
