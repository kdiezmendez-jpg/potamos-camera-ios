import SwiftUI

@main
struct PotamosCameraApp: App {
  @StateObject private var model = CameraModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .task { await model.start() }
    }
  }
}
