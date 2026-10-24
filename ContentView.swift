import HaishinKit
import SwiftUI

private let gold = Color(red: 0.79, green: 0.66, blue: 0.30)
private let panel = Color(red: 0.055, green: 0.10, blue: 0.14).opacity(0.72)

/// Aperçu caméra (vue Metal de HaishinKit).
struct CameraPreview: UIViewRepresentable {
  let view: MTHKView
  func makeUIView(context: Context) -> MTHKView { view }
  func updateUIView(_ uiView: MTHKView, context: Context) {}
}

struct ContentView: View {
  @EnvironmentObject var model: CameraModel
  @State private var hideTools = false

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Color.black.ignoresSafeArea()

        CameraPreview(view: model.preview)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture(coordinateSpace: .local) { p in
            model.focus(at: p, in: geo.size)
          }

        // Cadre rouge quand la caméra est à l'antenne
        if model.state == .live {
          Rectangle().strokeBorder(Color(red: 0.9, green: 0.28, blue: 0.3), lineWidth: 6)
            .ignoresSafeArea().allowsHitTesting(false)
        }

        VStack(spacing: 0) {
          topBar
          Spacer()
          if !hideTools { bottomPanel }
        }
        .padding(10)

        HStack {
          Spacer()
          rightColumn
        }
        .padding(.vertical, 10)
        .padding(.trailing, 10)
        .padding(.top, 50)

        if let msg = model.message {
          Text(msg)
            .multilineTextAlignment(.center)
            .font(.callout)
            .padding(16)
            .frame(maxWidth: 440)
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
            .onTapGesture { model.message = nil }
        }
      }
    }
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .sheet(isPresented: $model.showSettings) {
      SettingsView().environmentObject(model)
    }
  }

  private var topBar: some View {
    HStack(spacing: 8) {
      Text(model.cfg.name).font(.headline).foregroundStyle(gold).chip()
      HStack(spacing: 8) {
        Circle().fill(model.statusColor).frame(width: 12, height: 12)
        Text(model.statusText).font(.subheadline.bold())
      }
      .chip()
      Spacer()
      Text(model.info).font(.footnote).chip()
    }
    .padding(.trailing, 130)
  }

  private var rightColumn: some View {
    VStack(spacing: 6) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 6) {
          if !hideTools {
            tool("Réglages") {
              if model.isBusy { model.message = "Arrête d'abord le direct pour changer les réglages" } else { model.showSettings = true }
            }
            tool("Avant / Arrière") { model.switchCamera() }
            tool("Torche", on: model.torch) { model.toggleTorch() }
            tool("Mise au point auto", on: model.autoFocus) { model.toggleAutoFocus() }
            tool("Bloquer expo", on: model.aeLock) { model.toggleAELock() }
            tool("Bloquer balance", on: model.wbLock) { model.toggleWBLock() }
            tool("Mode PRO", on: model.pro) { model.togglePro() }
          }
          tool(hideTools ? "Afficher" : "Masquer", on: hideTools) { hideTools.toggle() }
        }
      }
      Button(action: model.toggleLive) {
        ZStack {
          Circle().fill(.white).frame(width: 84, height: 84)
          if model.isBusy {
            RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.9, green: 0.28, blue: 0.3)).frame(width: 40, height: 40)
          } else {
            Circle().fill(Color(red: 0.9, green: 0.28, blue: 0.3)).frame(width: 72, height: 72)
          }
        }
      }
      .accessibilityLabel(model.isBusy ? "Arrêter le direct" : "Démarrer le direct")
    }
    .frame(width: 132)
  }

  private func tool(_ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(on ? Color.black : .white)
        .frame(width: 132, height: 38)
        .background(on ? gold : panel, in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var bottomPanel: some View {
    VStack(spacing: 4) {
      row("Exposition \(String(format: "%+.1f", model.exposureBias))") {
        Slider(value: Binding(get: { model.exposureBias }, set: { model.setBias($0) }), in: model.biasRange)
          .disabled(model.pro)
      }
      row(String(format: "Zoom %.1fx", model.zoom)) {
        Slider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }), in: model.zoomRange)
      }
      if model.pro {
        row("ISO \(Int(model.iso))") {
          Slider(value: Binding(get: { model.iso }, set: { model.iso = $0; model.applyManual() }), in: model.isoRange)
        }
        let list = model.shutters
        row("Vitesse 1/\(list.isEmpty ? 50 : list[min(model.shutterIndex, list.count - 1)])") {
          Slider(value: Binding(get: { Double(model.shutterIndex) },
                                set: { model.shutterIndex = Int($0.rounded()); model.applyManual() }),
                 in: 0...Double(max(list.count - 1, 1)), step: 1)
        }
      }
    }
    .tint(gold)
    .padding(10)
    .background(panel, in: RoundedRectangle(cornerRadius: 12))
    .padding(.trailing, 140)
  }

  private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
    HStack {
      Text(label).font(.footnote).frame(width: 120, alignment: .leading)
      content()
    }
  }
}

private extension View {
  func chip() -> some View {
    padding(.horizontal, 12).padding(.vertical, 6)
      .background(panel, in: RoundedRectangle(cornerRadius: 12))
  }
}
