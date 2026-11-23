import ExpoModulesCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The bridge between the app's JavaScript and the rendering engine in `Engine/`.
/// Everything photographic lives there; this file only converts arguments and presents the photo picker.
public class OscuruEngineModule: Module {
  private let queue = DispatchQueue(label: "app.oscuru.engine", qos: .userInitiated)
  private lazy var engine: Engine = {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return Engine(outputDirectory: caches.appendingPathComponent("oscuru-renders", isDirectory: true))
  }()
  private var picker: PhotoPickerDelegate?

  public func definition() -> ModuleDefinition {
    Name("OscuruEngine")

    // Opens the system photo picker and copies the chosen photo's original file (the RAW file when
    // there is one) into the caches directory. Resolves with null when the person cancels.
    AsyncFunction("pickPhoto") { (promise: Promise) in
      guard self.picker == nil else {
        throw Exception(name: "PickerBusy", description: "A photo is already being chosen")
      }
      guard let presenter = self.appContext?.utilities?.currentViewController() else {
        throw Exception(name: "NoViewController", description: "Could not find a screen to show the photo picker on")
      }
      var configuration = PHPickerConfiguration()
      configuration.filter = .images
      configuration.selectionLimit = 1
      // "Current" hands over the file as it is stored, without converting a RAW to JPEG.
      configuration.preferredAssetRepresentationMode = .current
      let delegate = PhotoPickerDelegate { [weak self] result in
        self?.picker = nil
        switch result {
        case .success(let picked):
          promise.resolve(picked)
        case .failure(let error):
          promise.reject(Exception(name: "PickFailed", description: error.localizedDescription))
        }
      }
      self.picker = delegate
      let controller = PHPickerViewController(configuration: configuration)
      controller.delegate = delegate
      controller.presentationController?.delegate = delegate
      presenter.present(controller, animated: true)
    }.runOnQueue(.main)

    AsyncFunction("open") { (sessionId: String, uri: String) -> [String: Any] in
      guard let url = URL(string: uri), url.isFileURL else {
        throw Exception(name: "InvalidUri", description: "Expected a file:// URI, got \(uri)")
      }
      return try self.run { try self.engine.open(id: sessionId, url: url) }
    }.runOnQueue(queue)

    AsyncFunction("render") {
      (sessionId: String, recipe: [String: Any], toneTable: Data, cube: Data, options: [String: Any]) -> [String: Any] in
      let result = try self.run {
        try self.engine.render(
          id: sessionId,
          recipe: RenderRecipe(dictionary: recipe, toneTable: toneTable, cube: cube),
          options: RenderOptions(dictionary: options))
      }
      return [
        "uri": result.url.absoluteString,
        "width": result.width,
        "height": result.height,
        "statsWidth": result.statsWidth,
        "statsHeight": result.statsHeight,
        "statsPixels": result.statsPixels,
      ]
    }.runOnQueue(queue)

    AsyncFunction("close") { (sessionId: String) in
      self.engine.close(id: sessionId)
    }.runOnQueue(queue)
  }

  private func run<T>(_ work: () throws -> T) throws -> T {
    do {
      return try work()
    } catch let error as EngineError {
      throw Exception(name: "OscuruEngineError", description: error.description, code: error.code)
    }
  }
}

private final class PhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
  private let completion: (Result<[String: Any]?, Error>) -> Void
  private var finished = false

  init(completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
    self.completion = completion
  }

  private func finish(_ result: Result<[String: Any]?, Error>) {
    DispatchQueue.main.async {
      guard !self.finished else { return }
      self.finished = true
      self.completion(result)
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(.success(nil))
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider else {
      finish(.success(nil))
      return
    }
    // Prefer the RAW representation when the photo has one.
    let identifiers = provider.registeredTypeIdentifiers
    let raw = identifiers.first { UTType($0)?.conforms(to: .rawImage) ?? false }
    let image = identifiers.first { UTType($0)?.conforms(to: .image) ?? false }
    guard let identifier = raw ?? image else {
      finish(.failure(EngineError.cannotOpen("the selection is not an image")))
      return
    }
    let suggestedName = provider.suggestedName
    provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
      guard let url = url else {
        self.finish(.failure(error ?? EngineError.cannotOpen("the photo could not be loaded")))
        return
      }
      // The file only exists during this callback: copy it before returning.
      do {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("oscuru-imports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = url.pathExtension.isEmpty ? (UTType(identifier)?.preferredFilenameExtension ?? "img") : url.pathExtension
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try FileManager.default.copyItem(at: url, to: destination)
        let name = suggestedName.map { "\($0).\(fileExtension)" } ?? url.lastPathComponent
        self.finish(.success(["uri": destination.absoluteString, "name": name, "typeIdentifier": identifier]))
      } catch {
        self.finish(.failure(error))
      }
    }
  }
}
