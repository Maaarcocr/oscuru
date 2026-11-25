import AppIntents
import SwiftUI
import WidgetKit

/// Oscuru's camera as a control: in Control Center, on the Lock Screen, on the Action button, and
/// what makes Oscuru one of the apps the Camera Control can open.
struct CameraControl: ControlWidget {
    static let kind = "com.rudilosso.oscuru.controls.camera"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CameraControl.kind) {
            ControlWidgetButton(action: OscuruCameraIntent()) {
                Label(String(localized: "control.camera"), systemImage: "camera.aperture")
            }
        }
        .displayName("control.camera")
        .description("control.camera.description")
    }
}

@main
struct OscuruControls: WidgetBundle {
    var body: some Widget {
        CameraControl()
    }
}
