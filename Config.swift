import Foundation

/// Réglages de la caméra, gardés dans le téléphone.
struct Config: Codable, Equatable {
  var name = "Cam 1"
  var host = ""
  var port = 9001
  var latency = 120
  var resIndex = 0
  var fps = 30
  var bitrateMbps = 8.0
  var hevc = false
  var audio = false
  var stabilization = false
  var autoReconnect = true
  var lowLatency = true

  static let resolutions: [(w: Int, h: Int, label: String)] = [
    (1920, 1080, "1080p — conseillé"),
    (1280, 720, "720p — Wi-Fi faible"),
    (3840, 2160, "4K — iPhone récents"),
  ]
  static let fpsChoices = [25, 30, 60]

  var width: Int { Config.resolutions[min(max(resIndex, 0), Config.resolutions.count - 1)].w }
  var height: Int { Config.resolutions[min(max(resIndex, 0), Config.resolutions.count - 1)].h }
  var bitrate: Int { Int(min(max(bitrateMbps, 0.5), 50) * 1_000_000) }

  /// OBS (scène « PZ Cam ») attend en mode listener ; le téléphone appelle (caller).
  var url: URL? {
    URL(string: "srt://\(host.trimmingCharacters(in: .whitespaces)):\(port)?mode=caller&latency=\(latency)&streamid=potamos")
  }

  private static let key = "potamos.config"

  static func load() -> Config {
    guard let data = UserDefaults.standard.data(forKey: key),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    return cfg
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Config.key) }
  }
}
