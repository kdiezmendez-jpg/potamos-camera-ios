import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var model: CameraModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft = Config()
  @State private var hostError = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Mac (OBS)") {
          TextField("Adresse IP du Mac, ex. 192.168.1.69", text: $draft.host)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if hostError {
            Text("Obligatoire : l'adresse IP du Mac, par exemple 192.168.1.69").font(.footnote).foregroundStyle(.red)
          }
        }
        Section("Quelle caméra est cet iPhone ?") {
          Picker("Caméra", selection: Binding(
            get: { (draft.port - 9001) },
            set: { draft.port = 9001 + $0; draft.name = "Cam \($0 + 1)" })) {
            ForEach(0..<4) { Text("Cam \($0 + 1)").tag($0) }
          }
          .pickerStyle(.segmented)
          TextField("Nom", text: $draft.name)
          Stepper("Port \(draft.port)", value: $draft.port, in: 1024...65000)
          Stepper("Latence \(draft.latency) ms (80 câble, 120 Wi-Fi)", value: $draft.latency, in: 20...2000, step: 10)
        }
        Section("Vidéo") {
          Picker("Résolution", selection: $draft.resIndex) {
            ForEach(Config.resolutions.indices, id: \.self) { Text(Config.resolutions[$0].label).tag($0) }
          }
          Picker("Images par seconde", selection: $draft.fps) {
            ForEach(Config.fpsChoices, id: \.self) { Text("\($0) i/s").tag($0) }
          }
          Stepper(String(format: "Débit %.1f Mb/s (8 câble, 5 Wi-Fi)", draft.bitrateMbps), value: $draft.bitrateMbps, in: 1...30, step: 0.5)
          Picker("Codec", selection: $draft.hevc) {
            Text("H.264 — conseillé").tag(false)
            Text("H.265 / HEVC").tag(true)
          }
        }
        Section {
          Toggle("Faible latence (conseillé)", isOn: $draft.lowLatency)
          Toggle("Envoyer le son de l'iPhone", isOn: $draft.audio)
          Toggle("Stabilisation vidéo", isOn: $draft.stabilization)
          Toggle("Se reconnecter tout seul", isOn: $draft.autoReconnect)
        }
      }
      .navigationTitle("Réglages de la caméra")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Enregistrer", action: save).bold() }
      }
    }
    .onAppear { draft = model.cfg }
    .interactiveDismissDisabled()
  }

  private func save() {
    // Accepte aussi une adresse collée en entier, ex. « srt://192.168.1.69:9001 »
    var host = draft.host.trimmingCharacters(in: .whitespaces)
    if host.hasPrefix("srt://") { host.removeFirst(6) }
    if let i = host.firstIndex(of: ":") {
      if let p = Int(host[host.index(after: i)...].prefix { $0.isNumber }) { draft.port = p }
      host = String(host[..<i])
    }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    guard !host.isEmpty, !host.contains(" ") else { hostError = true; return }
    draft.host = host
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = "Cam 1" }
    model.cfg = draft
    dismiss()
    Task { await model.applySettings() }
  }
}
