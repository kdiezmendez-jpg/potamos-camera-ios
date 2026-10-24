import AVFoundation
import HaishinKit
import SRTHaishinKit
import SwiftUI
import UIKit
import VideoToolbox

/// Filme avec l'iPhone et envoie l'image en SRT vers OBS (scènes « PZ Cam » de Potamos Zoïs).
@MainActor
final class CameraModel: ObservableObject {
  enum State { case idle, connecting, live, retry, stopped }

  @Published var cfg = Config.load()
  @Published private(set) var state: State = .idle
  @Published var message: String?
  @Published private(set) var info = ""
  @Published var showSettings = false

  // Commandes caméra
  @Published private(set) var torch = false
  @Published private(set) var autoFocus = true
  @Published private(set) var aeLock = false
  @Published private(set) var wbLock = false
  @Published private(set) var pro = false
  @Published var exposureBias: Float = 0
  @Published var zoom: CGFloat = 1
  @Published var iso: Float = 400
  @Published var shutterIndex = 2
  @Published private(set) var biasRange: ClosedRange<Float> = -3...3
  @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1...5
  @Published private(set) var isoRange: ClosedRange<Float> = 50...3200
  @Published private(set) var position: AVCaptureDevice.Position = .back

  /// Vitesses d'obturation proposées en mode PRO (1/50 évite le scintillement des lampes en 50 Hz).
  var shutters: [Int] { [25, 30, 50, 60, 100, 120, 200, 250].filter { $0 >= cfg.fps } }

  let preview = MTHKView(frame: .zero)
  private let mixer = MediaMixer()
  private var connection: SRTConnection?
  private var stream: SRTStream?
  private var device: AVCaptureDevice?
  private var wantLive = false
  private var loop: Task<Void, Never>?
  private var ticker: Timer?
  private var started = false

  // MARK: Mise en route

  func start() async {
    guard !started else { return }
    started = true
    UIApplication.shared.isIdleTimerDisabled = true
    UIDevice.current.isBatteryMonitoringEnabled = true
    preview.videoGravity = .resizeAspect

    let videoOK = await AVCaptureDevice.requestAccess(for: .video)
    let audioOK = await AVCaptureDevice.requestAccess(for: .audio)
    guard videoOK else {
      message = "Potamos Caméra a besoin de la caméra.\nAutorise-la dans Réglages > Potamos Caméra."
      return
    }
    if !audioOK && cfg.audio { cfg.audio = false }

    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
    try? session.setActive(true)

    await mixer.addOutput(preview)
    await configureCamera()
    await configureAudio()
    await mixer.startRunning()

    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.tick() }
    }
    if cfg.host.isEmpty { showSettings = true }
  }

  private var preset: AVCaptureSession.Preset {
    switch cfg.resIndex {
    case 1: return .hd1280x720
    case 2: return .hd4K3840x2160
    default: return .hd1920x1080
    }
  }

  private func configureCamera() async {
    let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    device = dev
    let mirrored = position == .front
    let stabilization: AVCaptureVideoStabilizationMode = cfg.stabilization ? .standard : .off
    await mixer.setSessionPreset(preset)
    do {
      try await mixer.attachVideo(dev) { unit in
        unit.isVideoMirrored = mirrored
        unit.preferredVideoStabilizationMode = stabilization
      }
    } catch {
      message = "Caméra indisponible : \(error.localizedDescription)"
    }
    await mixer.setVideoOrientation(.landscapeRight)
    try? await mixer.setFrameRate(Float64(cfg.fps))
    readRanges()
    torch = false
    autoFocus = true
    aeLock = false
    wbLock = false
    if pro { applyManual() } else { setBias(exposureBias) }
  }

  private func configureAudio() async {
    try? await mixer.attachAudio(cfg.audio ? AVCaptureDevice.default(for: .audio) : nil)
  }

  private func readRanges() {
    guard let d = device else { return }
    biasRange = d.minExposureTargetBias...d.maxExposureTargetBias
    zoomRange = 1...max(1.01, min(d.maxAvailableVideoZoomFactor, 10))
    isoRange = d.activeFormat.minISO...d.activeFormat.maxISO
    iso = min(max(iso, isoRange.lowerBound), isoRange.upperBound)
    exposureBias = min(max(exposureBias, biasRange.lowerBound), biasRange.upperBound)
    zoom = 1
    shutterIndex = min(shutterIndex, max(shutters.count - 1, 0))
  }

  /// Applique les réglages enregistrés (appelé après la fenêtre Réglages).
  func applySettings() async {
    cfg.save()
    await configureCamera()
    await configureAudio()
    setState(.idle)
  }

  // MARK: Direct

  func toggleLive() {
    if wantLive { stopLive(); return }
    guard !cfg.host.trimmingCharacters(in: .whitespaces).isEmpty, cfg.url != nil else {
      message = "Entre d'abord l'adresse IP du Mac dans Réglages."
      showSettings = true
      return
    }
    wantLive = true
    message = nil
    setState(.connecting)
    loop = Task { await runLoop() }
  }

  func stopLive() {
    wantLive = false
    loop?.cancel()
    loop = nil
    Task { await closeStream() }
    setState(.idle)
  }

  private func runLoop() async {
    while wantLive && !Task.isCancelled {
      do {
        try await openStream()
        setState(.live)
        message = nil
        // Surveille la liaison : la bibliothèque ferme la connexion dès qu'un envoi échoue
        while wantLive, !Task.isCancelled, let c = connection, await c.connected {
          try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard wantLive, !Task.isCancelled else { break }
        message = "Liaison perdue, reconnexion…"
      } catch {
        message = explain(error)
        if !cfg.autoReconnect {
          wantLive = false
          await closeStream()
          setState(.stopped)
          return
        }
      }
      await closeStream()
      guard wantLive, !Task.isCancelled else { break }
      setState(.retry)
      try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
  }

  private func openStream() async throws {
    await closeStream()
    let c = SRTConnection()
    let s = SRTStream(connection: c)
    // Faible latence : H.264 Baseline, sans réordonnancement d'images, contrôle de débit « temps réel »
    let profile: String = cfg.hevc
      ? kVTProfileLevel_HEVC_Main_AutoLevel as String
      : (cfg.lowLatency ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_H264_High_AutoLevel) as String
    let video = VideoCodecSettings(
      videoSize: CGSize(width: cfg.width, height: cfg.height),
      bitRate: cfg.bitrate,
      profileLevel: profile,
      maxKeyFrameIntervalDuration: 1,
      allowFrameReordering: cfg.lowLatency ? false : nil,
      isLowLatencyRateControlEnabled: cfg.lowLatency && !cfg.hevc,
      expectedFrameRate: Double(cfg.fps)
    )
    try await s.setVideoSettings(video)
    await s.setExpectedMedias(cfg.audio ? [.video, .audio] : [.video])
    connection = c
    stream = s
    await mixer.addOutput(s)
    try await c.connect(cfg.url)
    await s.publish()
  }

  private func closeStream() async {
    if let s = stream {
      await mixer.removeOutput(s)
      await s.close()
    }
    if let c = connection { await c.close() }
    stream = nil
    connection = nil
  }

  private func explain(_ error: Error) -> String {
    "Le Mac ne répond pas.\nOBS est-il ouvert ? L'adresse \(cfg.host):\(cfg.port) est-elle la bonne ?\nL'iPhone et le Mac sont-ils sur le même réseau ?"
  }

  private func setState(_ s: State) { state = s }

  var statusText: String {
    switch state {
    case .idle: return cfg.host.isEmpty ? "Réglages à faire" : "Prêt → \(cfg.host):\(cfg.port)"
    case .connecting: return "Connexion au Mac…"
    case .live: return "EN DIRECT"
    case .retry: return "Reconnexion…"
    case .stopped: return "Arrêté"
    }
  }

  var statusColor: Color {
    switch state {
    case .idle: return .white
    case .connecting, .retry: return .orange
    case .live, .stopped: return Color(red: 0.9, green: 0.28, blue: 0.3)
    }
  }

  var isBusy: Bool { state == .live || state == .connecting || state == .retry }

  /// Une fois par seconde : débit envoyé, batterie, température.
  private func tick() async {
    var parts: [String] = []
    if state == .live, let c = connection, let p = await c.performanceData {
      parts.append(String(format: "%.1f Mb/s", p.mbpsSendRate))
    }
    parts.append("\(cfg.height)p\(cfg.fps)")
    let level = UIDevice.current.batteryLevel
    if level >= 0 {
      let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
      parts.append("Batterie \(Int(level * 100)) %" + (charging ? " ⚡" : ""))
    }
    switch ProcessInfo.processInfo.thermalState {
    case .serious: parts.append("⚠ chaud")
    case .critical: parts.append("⚠ très chaud")
    default: break
    }
    info = parts.joined(separator: "  ·  ")
  }

  // MARK: Réglages de l'image

  private func configure(_ body: (AVCaptureDevice) -> Void) {
    guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
    body(d)
    d.unlockForConfiguration()
  }

  func switchCamera() {
    position = position == .back ? .front : .back
    Task { await configureCamera() }
  }

  func toggleTorch() {
    guard let d = device, d.hasTorch else { message = "Pas de torche sur cette caméra"; return }
    torch.toggle()
    let on = torch
    configure { $0.torchMode = on ? .on : .off }
  }

  func toggleAutoFocus() {
    autoFocus.toggle()
    let on = autoFocus
    configure { d in
      let mode: AVCaptureDevice.FocusMode = on ? .continuousAutoFocus : .locked
      if d.isFocusModeSupported(mode) { d.focusMode = mode }
    }
  }

  func toggleAELock() {
    guard !pro else { return }
    aeLock.toggle()
    let on = aeLock
    configure { d in
      let mode: AVCaptureDevice.ExposureMode = on ? .locked : .continuousAutoExposure
      if d.isExposureModeSupported(mode) { d.exposureMode = mode }
    }
  }

  func toggleWBLock() {
    wbLock.toggle()
    let on = wbLock
    configure { d in
      let mode: AVCaptureDevice.WhiteBalanceMode = on ? .locked : .continuousAutoWhiteBalance
      if d.isWhiteBalanceModeSupported(mode) { d.whiteBalanceMode = mode }
    }
  }

  func setBias(_ value: Float) {
    exposureBias = value
    configure { $0.setExposureTargetBias(value, completionHandler: nil) }
  }

  func setZoom(_ value: CGFloat) {
    zoom = value
    configure { $0.videoZoomFactor = min(max(value, 1), $0.maxAvailableVideoZoomFactor) }
  }

  /// Toucher l'écran : mise au point et exposition sur ce point.
  func focus(at point: CGPoint, in size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    var p = CGPoint(x: point.x / size.width, y: point.y / size.height)
    if position == .front { p.x = 1 - p.x }
    let keepAuto = autoFocus
    configure { d in
      if d.isFocusPointOfInterestSupported {
        d.focusPointOfInterest = p
        d.focusMode = keepAuto ? .continuousAutoFocus : .autoFocus
      }
      if !self.pro, !self.aeLock, d.isExposurePointOfInterestSupported {
        d.exposurePointOfInterest = p
        d.exposureMode = .continuousAutoExposure
      }
    }
  }

  func togglePro() {
    pro.toggle()
    if pro {
      applyManual()
    } else {
      configure { d in
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
      }
      setBias(exposureBias)
    }
  }

  /// Mode PRO : ISO et vitesse d'obturation fixes.
  func applyManual() {
    guard pro, let d = device, d.isExposureModeSupported(.custom) else { return }
    let list = shutters
    let denom = list.isEmpty ? 50 : list[min(max(shutterIndex, 0), list.count - 1)]
    let fmt = d.activeFormat
    var duration = CMTime(value: 1, timescale: CMTimeScale(denom))
    if duration < fmt.minExposureDuration { duration = fmt.minExposureDuration }
    if duration > fmt.maxExposureDuration { duration = fmt.maxExposureDuration }
    let isoValue = min(max(iso, fmt.minISO), fmt.maxISO)
    configure { $0.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil) }
  }
}
