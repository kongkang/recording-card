import CoreLocation
import Flutter
import Foundation
import HealthKit

/// 本机健康与位置采集。
///
/// 只读取用户在系统授权页里实际允许的类型，按采样间隔收成每窗一个点，
/// 先写入沙盒暂存，再由 Flutter 落进 SQLite。不上传，不写回 HealthKit。
/// 临床病历（CDA）没有 `com.apple.developer.healthkit.access`，这里不请求。
/// 后台唤醒还需要开发者门户里的 HealthKit Background Delivery；
/// 没有这项能力时，观察者注册会失败，前台打开开关和回到前台仍会补齐。
final class HealthSignalBridge: NSObject, CLLocationManagerDelegate {
  static let shared = HealthSignalBridge()

  private let healthStore = HKHealthStore()
  private let locationManager = CLLocationManager()
  private let spoolQueue = DispatchQueue(label: "com.reai.recordingcard.health-spool")
  private let workQueue = DispatchQueue(label: "com.reai.recordingcard.health-work")

  private var channel: FlutterMethodChannel?
  private var observers: [HKObserverQuery] = []
  private var phaseTimer: DispatchSourceTimer?
  private var specs: [SignalSpec] = []
  private var jobs: [ImportJob] = []
  private var importing = false
  private var expectingOneShot = false
  private var pendingAccess: PendingAccess?
  private var accessTimeout: DispatchWorkItem?
  private var askedAlways = false
  private var deliveryGeneration = 0

  private let enabledKey = "rc.health.enabled"
  private let intervalKey = "rc.health.intervalMs"
  private let phaseKey = "rc.health.phaseMs"

  private override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func bootstrap() {
    guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
    startCollection(intervalMs: storedIntervalMs(), phaseMs: storedPhaseMs())
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.reai.recordingcard/health_signal",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      result(infoPayload())
    case "requestAccess":
      requestAccess(result: result)
    case "setCollectionActive":
      let args = call.arguments as? [String: Any] ?? [:]
      let active = args["active"] as? Bool ?? false
      let interval = args["intervalMs"] as? Int ?? storedIntervalMs()
      let phase = args["phaseMs"] as? Int ?? storedPhaseMs()
      UserDefaults.standard.set(active, forKey: enabledKey)
      UserDefaults.standard.set(interval, forKey: intervalKey)
      UserDefaults.standard.set(phase, forKey: phaseKey)
      if active {
        startCollection(intervalMs: interval, phaseMs: phase)
      } else {
        stopCollection()
      }
      result(nil)
    case "catchUp":
      let args = call.arguments as? [String: Any] ?? [:]
      enqueueCatchUp(args: args, quick: false, trigger: nil) {
        DispatchQueue.main.async { result(nil) }
      }
    case "drainSpool":
      result(drainSpool(maxItems: 400))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func infoPayload() -> [String: Any] {
    let available = HKHealthStore.isHealthDataAvailable()
    return [
      "available": available,
      "clinicalRecords": false,
      "clinicalReason": "签名未包含 com.apple.developer.healthkit.access，临床病历（CDA）不采集",
      "detail": available ? "" : "这台设备没有健康数据",
    ]
  }

  private func requestAccess(result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result([
        "available": false,
        "requested": 0,
        "location": "unsupported",
        "clinicalSkipped": true,
        "error": "这台设备没有健康数据",
      ])
      return
    }
    let types = authorizationTypes()
    healthStore.requestAuthorization(toShare: [], read: types) { [weak self] success, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.finishHealthThenLocation(
          success: success,
          error: error,
          requested: types.count,
          result: result
        )
      }
    }
  }

  private func finishHealthThenLocation(
    success: Bool,
    error: Error?,
    requested: Int,
    result: @escaping FlutterResult
  ) {
    if !success {
      result([
        "available": false,
        "requested": requested,
        "location": locationStatusText(),
        "clinicalSkipped": true,
        "error": error?.localizedDescription ?? "系统没有完成健康授权",
      ])
      return
    }
    let status = locationManager.authorizationStatus
    if status == .notDetermined {
      pendingAccess = PendingAccess(result: result, requested: requested)
      accessTimeout?.cancel()
      let timeout = DispatchWorkItem { [weak self] in
        self?.completePendingAccess()
      }
      accessTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
      locationManager.requestWhenInUseAuthorization()
      return
    }
    askAlwaysIfNeeded()
    result(accessPayload(requested: requested))
  }

  private func completePendingAccess() {
    guard let pending = pendingAccess else { return }
    pendingAccess = nil
    accessTimeout?.cancel()
    let status = locationManager.authorizationStatus
    askAlwaysIfNeeded()
    pending.result(accessPayload(requested: pending.requested))
  }

  private func askAlwaysIfNeeded() {
    guard !askedAlways else { return }
    guard locationManager.authorizationStatus == .authorizedWhenInUse else { return }
    askedAlways = true
    locationManager.requestAlwaysAuthorization()
  }

  private func accessPayload(requested: Int) -> [String: Any] {
    [
      "available": true,
      "requested": requested,
      "location": locationStatusText(),
      "clinicalSkipped": true,
    ]
  }

  private func locationStatusText() -> String {
    switch locationManager.authorizationStatus {
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whenInUse"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    if status == .authorizedWhenInUse {
      askAlwaysIfNeeded()
    }
    if pendingAccess != nil && status != .notDetermined {
      completePendingAccess()
    }
    if UserDefaults.standard.bool(forKey: enabledKey) {
      startLocationUpdates()
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    let phased = expectingOneShot
    expectingOneShot = false
    spoolLocation(location, phased: phased, place: nil)
    CLGeocoder().reverseGeocodeLocation(location) { [weak self] marks, _ in
      self?.spoolLocation(location, phased: phased, place: self?.placeLine(marks?.first))
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    expectingOneShot = false
  }

  private func placeLine(_ mark: CLPlacemark?) -> String? {
    guard let mark else { return nil }
    let parts = [mark.locality, mark.subLocality, mark.thoroughfare, mark.name]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var seen = Set<String>()
    let unique = parts.filter { seen.insert($0).inserted }
    if unique.isEmpty { return nil }
    return unique.prefix(3).joined(separator: " ")
  }

  private func spoolLocation(_ location: CLLocation, phased: Bool, place: String?) {
    let nowMs = Int(location.timestamp.timeIntervalSince1970 * 1000)
    let startMs = phased ? phaseStampMs(now: location.timestamp) : nowMs
    var payload: [String: Any] = [
      "lat": location.coordinate.latitude,
      "lng": location.coordinate.longitude,
      "accuracy": location.horizontalAccuracy,
    ]
    if let place, !place.isEmpty {
      payload["place"] = place
    }
    let text = (try? JSONSerialization.data(withJSONObject: payload))
      .flatMap { String(data: $0, encoding: .utf8) }
    var metadata: [String: Any] = ["method": phased ? "phase" : "significant"]
    if let place { metadata["place"] = place }
    let draft: [String: Any] = [
      "type": "location",
      "startMs": startMs,
      "endMs": startMs,
      "valueText": text ?? "",
      "unit": "",
      "sourceName": "本机定位",
      "sourceBundle": phased ? "location.phased" : "location.significant",
      "aggregation": "point",
      "metadata": metadata,
    ]
    spool([draft])
    notifySpool()
  }

  private func startCollection(intervalMs: Int, phaseMs: Int) {
    guard HKHealthStore.isHealthDataAvailable() else { return }
    ensureSpecs()
    deliveryGeneration += 1
    stopObserverQueries()
    for spec in specs {
      guard let sampleType = spec.sampleType else { continue }
      let typeId = spec.typeId
      let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
        [weak self] _, completion, _ in
        self?.enqueueCatchUp(
          args: [:],
          quick: true,
          trigger: typeId,
          completion: completion
        )
      }
      observers.append(query)
      healthStore.execute(query)
      healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
    }
    startPhaseTimer(intervalMs: intervalMs, phaseMs: phaseMs)
    startLocationUpdates()
  }

  private func stopCollection() {
    deliveryGeneration += 1
    let generation = deliveryGeneration
    stopObserverQueries()
    phaseTimer?.cancel()
    phaseTimer = nil
    locationManager.stopMonitoringSignificantLocationChanges()
    expectingOneShot = false
    healthStore.disableAllBackgroundDelivery { [weak self] _, _ in
      guard let self, generation == self.deliveryGeneration else { return }
    }
  }

  private func stopObserverQueries() {
    for query in observers {
      healthStore.stop(query)
    }
    observers.removeAll()
  }

  private func startLocationUpdates() {
    let status = locationManager.authorizationStatus
    guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
    if status == .authorizedAlways {
      locationManager.allowsBackgroundLocationUpdates = true
      locationManager.pausesLocationUpdatesAutomatically = false
      locationManager.startMonitoringSignificantLocationChanges()
    }
    if phaseTimer == nil {
      startPhaseTimer(intervalMs: storedIntervalMs(), phaseMs: storedPhaseMs())
    }
  }

  private func startPhaseTimer(intervalMs: Int, phaseMs: Int) {
    phaseTimer?.cancel()
    let interval = max(60.0, Double(intervalMs) / 1000.0)
    let phase = min(max(0.0, Double(phaseMs) / 1000.0), interval - 1)
    let now = Date().timeIntervalSince1970
    let window = floor(now / interval) * interval
    var next = window + phase
    if next <= now + 0.05 { next += interval }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + (next - now), repeating: interval)
    timer.setEventHandler { [weak self] in
      self?.requestPhasedLocation()
    }
    timer.resume()
    phaseTimer = timer
  }

  private func requestPhasedLocation() {
    let status = locationManager.authorizationStatus
    guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
    expectingOneShot = true
    locationManager.requestLocation()
  }

  private func phaseStampMs(now: Date) -> Int {
    let interval = Double(storedIntervalMs()) / 1000.0
    let phase = min(Double(storedPhaseMs()) / 1000.0, max(0, interval - 1))
    let t = now.timeIntervalSince1970
    let window = floor(t / interval) * interval
    var stamp = window + phase
    if stamp - t > 1 { stamp -= interval }
    return Int(stamp * 1000)
  }

  private func storedIntervalMs() -> Int {
    let value = UserDefaults.standard.integer(forKey: intervalKey)
    if value < 60_000 { return 60_000 }
    return value
  }

  private func storedPhaseMs() -> Int {
    let interval = storedIntervalMs()
    let value = UserDefaults.standard.object(forKey: phaseKey) as? Int ?? 30_000
    return min(max(0, value), interval - 1000)
  }

  private func enqueueCatchUp(
    args: [String: Any],
    quick: Bool,
    trigger: String?,
    completion: (() -> Void)? = nil,
    done: (() -> Void)? = nil
  ) {
    let untilMs = args["untilMs"] as? Int ?? Int(Date().timeIntervalSince1970 * 1000)
    let intervalMs = args["intervalMs"] as? Int ?? storedIntervalMs()
    let phaseMs = args["phaseMs"] as? Int ?? storedPhaseMs()
    let defaultSinceMs = args["defaultSinceMs"] as? Int ?? (untilMs - (quick ? 6 * 3_600_000 : 30 * 86_400_000))
    let sinceByType = (args["sinceByType"] as? [String: Int]) ?? [:]
    let job = ImportJob(
      untilMs: untilMs,
      defaultSinceMs: defaultSinceMs,
      sinceByType: sinceByType,
      intervalMs: max(60_000, intervalMs),
      phaseMs: phaseMs,
      quick: quick || (args["quick"] as? Bool ?? false),
      trigger: trigger,
      completion: completion,
      done: done
    )
    workQueue.async { [weak self] in
      guard let self else {
        completion?()
        done?()
        return
      }
      self.jobs.append(job)
      self.pump()
      self.scheduleCompletionTimeout(for: job)
    }
  }

  private func scheduleCompletionTimeout(for job: ImportJob) {
    guard job.completion != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      job.callCompletion()
    }
  }

  private func pump() {
    guard !importing, !jobs.isEmpty else { return }
    importing = true
    let job = jobs.removeFirst()
    run(job) { [weak self] in
      self?.workQueue.async {
        job.callCompletion()
        job.done?()
        self?.importing = false
        self?.pump()
      }
    }
  }

  private func run(_ job: ImportJob, finished: @escaping () -> Void) {
    guard HKHealthStore.isHealthDataAvailable() else {
      finished()
      return
    }
    ensureSpecs()
    let selected = job.quick
      ? specs.filter { Self.quickTypeIds.contains($0.typeId) || $0.typeId == job.trigger }
      : specs
    if selected.isEmpty {
      finished()
      return
    }
    let group = DispatchGroup()
    for spec in selected {
      group.enter()
      query(spec, job: job) { [weak self] rows in
        self?.workQueue.async {
          self?.spool(rows)
          self?.rememberCursors(rows)
          group.leave()
        }
      }
    }
    group.notify(queue: workQueue) {
      if job.quick {
        DispatchQueue.main.async { self.notifySpool() }
      }
      finished()
    }
  }

  private func query(_ spec: SignalSpec, job: ImportJob, done: @escaping ([[String: Any]]) -> Void) {
    let since = sinceDate(for: spec.typeId, job: job)
    let until = Date(timeIntervalSince1970: Double(job.untilMs) / 1000.0)
    if since >= until {
      done([])
      return
    }
    switch spec.kind {
    case .quantity(let type):
      queryQuantity(type, typeId: spec.typeId, since: since, until: until, job: job, done: done)
    case .category(let type):
      queryCategory(type, typeId: spec.typeId, since: since, until: until, done: done)
    case .characteristic(let type):
      done(readCharacteristic(type, typeId: spec.typeId))
    case .workout:
      queryWorkouts(since: since, until: until, done: done)
    case .activitySummary:
      queryActivity(since: since, until: until, done: done)
    case .sample(let type, let label):
      queryGenericSample(type, typeId: spec.typeId, label: label, since: since, until: until, done: done)
    case .authorizeOnly:
      done([])
    }
  }

  private func sinceDate(for typeId: String, job: ImportJob) -> Date {
    var ms = job.defaultSinceMs
    if let passed = job.sinceByType[typeId], passed > 0 {
      ms = min(ms, passed)
    }
    let stored = UserDefaults.standard.integer(forKey: cursorKey(typeId))
    if stored > 0 {
      ms = min(ms, stored - job.intervalMs)
    }
    if job.quick {
      let cap = job.untilMs - 6 * 3_600_000
      if ms < cap { ms = cap }
    }
    return Date(timeIntervalSince1970: Double(ms) / 1000.0)
  }

  private func queryQuantity(
    _ type: HKQuantityType,
    typeId: String,
    since: Date,
    until: Date,
    job: ImportJob,
    done: @escaping ([[String: Any]]) -> Void
  ) {
    let cumulative = type.aggregationStyle == .cumulative
    var components = DateComponents()
    let seconds = job.intervalMs / 1000
    if seconds % 60 == 0 {
      components.minute = max(1, seconds / 60)
    } else {
      components.second = seconds
    }
    let predicate = HKQuery.predicateForSamples(withStart: since, end: until, options: [])
    let query = HKStatisticsCollectionQuery(
      quantityType: type,
      quantitySamplePredicate: predicate,
      options: cumulative ? .cumulativeSum : .discreteAverage,
      anchorDate: Date(timeIntervalSince1970: 0),
      intervalComponents: components
    )
    query.initialResultsHandler = { [weak self] _, results, error in
      guard let self else {
        done([])
        return
      }
      if error != nil || results == nil {
        self.queryQuantitySamples(type, typeId: typeId, since: since, until: until, cumulative: cumulative, done: done)
        return
      }
      var rows: [[String: Any]] = []
      let phase = TimeInterval(min(max(0, job.phaseMs), job.intervalMs - 1000)) / 1000.0
      results?.enumerateStatistics(from: since, to: until) { stats, _ in
        let quantity = cumulative ? stats.sumQuantity() : stats.averageQuantity()
        guard let quantity, let reading = self.doubleValue(quantity, typeId: typeId) else { return }
        if cumulative && reading.value == 0 { return }
        if reading.value.isNaN { return }
        let start = stats.startDate.addingTimeInterval(phase)
        if start < since || start >= until { return }
        let end = stats.startDate.addingTimeInterval(TimeInterval(job.intervalMs) / 1000.0)
        rows.append(self.draft(
          typeId: typeId,
          start: start,
          end: end,
          value: reading.value,
          text: nil,
          unit: reading.unit,
          sourceName: "健康",
          sourceBundle: "healthkit",
          aggregation: cumulative ? "sum" : "average",
          metadata: ["method": "statistics"]
        ))
      }
      done(rows)
    }
    healthStore.execute(query)
  }

  private func queryQuantitySamples(
    _ type: HKQuantityType,
    typeId: String,
    since: Date,
    until: Date,
    cumulative: Bool,
    done: @escaping ([[String: Any]]) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: since, end: until, options: [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
    let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 8000, sortDescriptors: [sort]) {
      [weak self] _, samples, _ in
      guard let self else {
        done([])
        return
      }
      var rows: [[String: Any]] = []
      for case let sample as HKQuantitySample in samples ?? [] {
        guard let reading = self.doubleValue(sample.quantity, typeId: typeId) else { continue }
        if cumulative && reading.value == 0 { continue }
        rows.append(self.draft(
          typeId: typeId,
          start: sample.startDate,
          end: sample.endDate,
          value: reading.value,
          text: nil,
          unit: reading.unit,
          sourceName: sample.sourceRevision.source.name,
          sourceBundle: sample.sourceRevision.source.bundleIdentifier,
          aggregation: "raw",
          metadata: ["cumulative": cumulative]
        ))
      }
      done(rows)
    }
    healthStore.execute(query)
  }

  private func queryCategory(
    _ type: HKCategoryType,
    typeId: String,
    since: Date,
    until: Date,
    done: @escaping ([[String: Any]]) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: since, end: until, options: [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
    let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 4000, sortDescriptors: [sort]) {
      [weak self] _, samples, _ in
      guard let self else {
        done([])
        return
      }
      var rows: [[String: Any]] = []
      for case let sample as HKCategorySample in samples ?? [] {
        rows.append(self.draft(
          typeId: typeId,
          start: sample.startDate,
          end: sample.endDate,
          value: Double(sample.value),
          text: self.categoryText(typeId: typeId, value: sample.value),
          unit: nil,
          sourceName: sample.sourceRevision.source.name,
          sourceBundle: sample.sourceRevision.source.bundleIdentifier,
          aggregation: "span",
          metadata: ["category": sample.value]
        ))
      }
      done(rows)
    }
    healthStore.execute(query)
  }

  private func queryWorkouts(since: Date, until: Date, done: @escaping ([[String: Any]]) -> Void) {
    let predicate = HKQuery.predicateForSamples(withStart: since, end: until, options: [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
    let query = HKSampleQuery(
      sampleType: HKWorkoutType.workoutType(),
      predicate: predicate,
      limit: 500,
      sortDescriptors: [sort]
    ) { [weak self] _, samples, _ in
      guard let self else {
        done([])
        return
      }
      var rows: [[String: Any]] = []
      for case let workout as HKWorkout in samples ?? [] {
        rows.append(self.draft(
          typeId: "workout",
          start: workout.startDate,
          end: workout.endDate,
          value: workout.duration,
          text: self.workoutName(workout.workoutActivityType),
          unit: "s",
          sourceName: workout.sourceRevision.source.name,
          sourceBundle: workout.sourceRevision.source.bundleIdentifier,
          aggregation: "span",
          metadata: ["activity": workout.workoutActivityType.rawValue]
        ))
      }
      done(rows)
    }
    healthStore.execute(query)
  }

  private func queryActivity(since: Date, until: Date, done: @escaping ([[String: Any]]) -> Void) {
    let calendar = Calendar.current
    let startParts = calendar.dateComponents([.year, .month, .day], from: since)
    let endParts = calendar.dateComponents([.year, .month, .day], from: until.addingTimeInterval(86_400))
    let predicate = HKQuery.predicateForActivitySummaries(betweenStart: startParts, end: endParts)
    let query = HKActivitySummaryQuery(predicate: predicate) { [weak self] _, summaries, _ in
      guard let self else {
        done([])
        return
      }
      var rows: [[String: Any]] = []
      for summary in summaries ?? [] {
        guard let day = calendar.date(from: summary.dateComponents(for: calendar)) else { continue }
        let move = (try? summary.activeEnergyBurned.doubleValue(for: .kilocalorie())) ?? 0
        let exercise = (try? summary.appleExerciseTime.doubleValue(for: .minute())) ?? 0
        let stand = (try? summary.appleStandHours.doubleValue(for: .count())) ?? 0
        if move == 0 && exercise == 0 && stand == 0 { continue }
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        rows.append(self.draft(
          typeId: "activity_summary",
          start: day,
          end: end,
          value: move,
          text: "活动 \(Int(move.rounded())) 千卡 · 锻炼 \(Int(exercise.rounded())) 分 · 站立 \(Int(stand.rounded()))",
          unit: "kcal",
          sourceName: "健康",
          sourceBundle: "healthkit.activity",
          aggregation: "span",
          metadata: ["exerciseMin": exercise, "standHours": stand]
        ))
      }
      done(rows)
    }
    healthStore.execute(query)
  }

  private func queryGenericSample(
    _ type: HKSampleType,
    typeId: String,
    label: String,
    since: Date,
    until: Date,
    done: @escaping ([[String: Any]]) -> Void
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: since, end: until, options: [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
    let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 500, sortDescriptors: [sort]) {
      [weak self] _, samples, _ in
      guard let self else {
        done([])
        return
      }
      var rows: [[String: Any]] = []
      for sample in samples ?? [] {
        var value: Double?
        var text = label
        if #available(iOS 14.0, *), let ecg = sample as? HKElectrocardiogram {
          if let rate = ecg.averageHeartRate {
            value = try? rate.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
          }
          text = self.ecgText(ecg.classification)
        } else if #available(iOS 18.0, *), let mind = sample as? HKStateOfMind {
          value = mind.valence
          text = mind.kind == .dailyMood ? "今日心情" : "当下情绪"
        }
        rows.append(self.draft(
          typeId: typeId,
          start: sample.startDate,
          end: sample.endDate,
          value: value,
          text: text,
          unit: value == nil ? nil : (typeId == "electrocardiogram" ? "bpm" : nil),
          sourceName: sample.sourceRevision.source.name,
          sourceBundle: sample.sourceRevision.source.bundleIdentifier,
          aggregation: "span",
          metadata: [:]
        ))
      }
      done(rows)
    }
    healthStore.execute(query)
  }

  private func readCharacteristic(_ type: HKCharacteristicType, typeId: String) -> [[String: Any]] {
    switch typeId {
    case "biological_sex":
      guard let sex = try? healthStore.biologicalSex().biologicalSex, sex != .notSet else { return [] }
      let text: String
      switch sex {
      case .female: text = "女"
      case .male: text = "男"
      case .other: text = "其他"
      default: return []
      }
      return [profileDraft(typeId: typeId, text: text)]
    case "blood_type":
      guard let blood = try? healthStore.bloodType().bloodType, blood != .notSet else { return [] }
      return [profileDraft(typeId: typeId, text: bloodText(blood))]
    case "date_of_birth":
      guard let parts = try? healthStore.dateOfBirthComponents(),
            let year = parts.year, year > 1900 else { return [] }
      let month = parts.month ?? 1
      let day = parts.day ?? 1
      return [profileDraft(typeId: typeId, text: String(format: "%04d-%02d-%02d", year, month, day))]
    case "fitzpatrick_skin_type":
      guard let skin = try? healthStore.fitzpatrickSkinType().skinType, skin != .notSet else { return [] }
      return [profileDraft(typeId: typeId, text: "Fitzpatrick \(skin.rawValue)")]
    case "wheelchair_use":
      guard let use = try? healthStore.wheelchairUse().wheelchairUse, use != .notSet else { return [] }
      return [profileDraft(typeId: typeId, text: use == .yes ? "使用轮椅" : "不使用轮椅")]
    case "activity_move_mode":
      if #available(iOS 14.0, *) {
        guard let mode = try? healthStore.activityMoveMode().activityMoveMode, mode != .notSet else { return [] }
        return [profileDraft(typeId: typeId, text: mode == .activeEnergy ? "活动能量" : "移动时间")]
      }
      return []
    default:
      return []
    }
  }

  private func profileDraft(typeId: String, text: String) -> [String: Any] {
    draft(
      typeId: typeId,
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 0),
      value: nil,
      text: text,
      unit: nil,
      sourceName: "健康",
      sourceBundle: "healthkit.profile",
      aggregation: "point",
      metadata: ["profile": true]
    )
  }

  private func draft(
    typeId: String,
    start: Date,
    end: Date,
    value: Double?,
    text: String?,
    unit: String?,
    sourceName: String,
    sourceBundle: String,
    aggregation: String,
    metadata: [String: Any]
  ) -> [String: Any] {
    var row: [String: Any] = [
      "type": typeId,
      "startMs": Int(start.timeIntervalSince1970 * 1000),
      "endMs": Int(end.timeIntervalSince1970 * 1000),
      "sourceName": sourceName,
      "sourceBundle": sourceBundle,
      "aggregation": aggregation,
      "metadata": metadata,
    ]
    if let value, value.isFinite { row["valueNum"] = value }
    if let text, !text.isEmpty { row["valueText"] = text }
    if let unit, !unit.isEmpty { row["unit"] = unit }
    if metadata["cumulative"] as? Bool == true { row["cumulative"] = true }
    return row
  }

  private func doubleValue(_ quantity: HKQuantity, typeId: String) -> (value: Double, unit: String)? {
    for candidate in unitCandidates(typeId) {
      if let value = try? quantity.doubleValue(for: candidate.unit), value.isFinite {
        let scaled = candidate.percent ? value * 100 : value
        return (scaled, candidate.label)
      }
    }
    return nil
  }

  private func unitCandidates(_ typeId: String) -> [(unit: HKUnit, label: String, percent: Bool)] {
    let perMinute = HKUnit.count().unitDivided(by: .minute())
    if typeId.contains("heart_rate") {
      return [(perMinute, "bpm", false)]
    }
    switch typeId {
    case "heart_rate_variability_sdnn":
      return [(HKUnit.secondUnit(with: .milli), "ms", false)]
    case "oxygen_saturation", "body_fat_percentage", "walking_asymmetry_percentage",
         "walking_double_support_percentage", "atrial_fibrillation_burden":
      return [(HKUnit.percent(), "%", true)]
    case "respiratory_rate":
      return [(perMinute, "次/分", false)]
    case "body_mass", "lean_body_mass":
      return [(.gramUnit(with: .kilo), "kg", false)]
    case "height", "waist_circumference", "walking_step_length":
      return [(.meter(), "m", false)]
    case "body_temperature", "basal_body_temperature", "apple_sleeping_wrist_temperature",
         "water_temperature":
      return [(.degreeCelsius(), "°C", false)]
    case "blood_pressure_systolic", "blood_pressure_diastolic":
      return [(.millimeterOfMercury(), "mmHg", false)]
    case "blood_glucose":
      return [(HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci)), "mg/dL", false)]
    case "vo2_max":
      return [(HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute())), "ml/kg/min", false)]
    case "environmental_audio_exposure", "headphone_audio_exposure":
      return [(.decibelAWeightedSoundPressureLevel(), "dB", false)]
    default:
      break
    }
    if typeId.contains("distance") || typeId == "six_minute_walk_test_distance" || typeId == "underwater_depth" {
      return [(.meter(), "m", false)]
    }
    if typeId.contains("energy") || typeId.contains("dietary_energy") {
      return [(.kilocalorie(), "kcal", false)]
    }
    if typeId.contains("speed") {
      return [(HKUnit.meter().unitDivided(by: .second()), "m/s", false)]
    }
    if typeId.contains("time") || typeId == "apple_move_time" || typeId == "time_in_daylight" {
      return [(.minute(), "min", false), (.second(), "s", false)]
    }
    if typeId.contains("percentage") || typeId.contains("fraction") {
      return [(HKUnit.percent(), "%", true)]
    }
    return [(.count(), "次", false), (.kilocalorie(), "kcal", false), (.gram(), "g", false), (.meter(), "m", false)]
  }

  private func categoryText(typeId: String, value: Int) -> String {
    if typeId == "sleep_analysis" {
      switch value {
      case 0: return "在床"
      case 1: return "睡眠"
      case 2: return "清醒"
      case 3: return "核心"
      case 4: return "深睡"
      case 5: return "REM"
      default: return "睡眠"
      }
    }
    if typeId == "apple_stand_hour" {
      return value == 0 ? "已站立" : "未站立"
    }
    if typeId == "mindful_session" { return "正念" }
    return ""
  }

  private func workoutName(_ type: HKWorkoutActivityType) -> String {
    switch type {
    case .running: return "跑步"
    case .walking: return "步行"
    case .cycling: return "骑行"
    case .swimming: return "游泳"
    case .hiking: return "徒步"
    case .yoga: return "瑜伽"
    case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
    case .highIntensityIntervalTraining: return "间歇训练"
    case .rowing: return "划船"
    case .elliptical: return "椭圆机"
    case .stairClimbing: return "爬楼"
    case .coreTraining: return "核心训练"
    case .cooldown: return "放松"
    default: return "运动"
    }
  }

  private func ecgText(_ classification: HKElectrocardiogram.Classification) -> String {
    switch classification {
    case .sinusRhythm: return "窦性心律"
    case .atrialFibrillation: return "房颤"
    case .inconclusiveLowHeartRate: return "心率偏低，结果不确定"
    case .inconclusiveHighHeartRate: return "心率偏高，结果不确定"
    case .inconclusivePoorReading: return "信号不佳"
    case .inconclusiveOther: return "结果不确定"
    default: return "心电图"
    }
  }

  private func bloodText(_ blood: HKBloodType) -> String {
    switch blood {
    case .aPositive: return "A+"
    case .aNegative: return "A-"
    case .bPositive: return "B+"
    case .bNegative: return "B-"
    case .abPositive: return "AB+"
    case .abNegative: return "AB-"
    case .oPositive: return "O+"
    case .oNegative: return "O-"
    default: return ""
    }
  }

  private func spool(_ rows: [[String: Any]]) {
    guard !rows.isEmpty else { return }
    spoolQueue.sync {
      let dir = spoolDirectory()
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var rest = rows
      while !rest.isEmpty {
        let count = min(300, rest.count)
        let chunk = Array(rest.prefix(count))
        rest.removeFirst(count)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: chunk) {
          try? data.write(to: url, options: .atomic)
        }
      }
    }
  }

  private func drainSpool(maxItems: Int) -> [[String: Any]] {
    spoolQueue.sync {
      let dir = spoolDirectory()
      let files = ((try? FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil
      )) ?? [])
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
      var out: [[String: Any]] = []
      var used: [URL] = []
      for file in files {
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
          used.append(file)
          continue
        }
        out.append(contentsOf: rows)
        used.append(file)
        if out.count >= maxItems { break }
      }
      for file in used {
        try? FileManager.default.removeItem(at: file)
      }
      return out
    }
  }

  private func spoolDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("health_signal_spool", isDirectory: true)
  }

  private func notifySpool() {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onSpoolReady", arguments: nil)
    }
  }

  private func rememberCursors(_ rows: [[String: Any]]) {
    for row in rows {
      guard let type = row["type"] as? String else { continue }
      let end = row["endMs"] as? Int ?? row["startMs"] as? Int ?? 0
      let key = cursorKey(type)
      let prev = UserDefaults.standard.integer(forKey: key)
      if end > prev { UserDefaults.standard.set(end, forKey: key) }
    }
  }

  private func cursorKey(_ typeId: String) -> String {
    "rc.health.cursor.\(typeId)"
  }

  private func ensureSpecs() {
    if specs.isEmpty { specs = Self.buildSpecs() }
  }

  private func authorizationTypes() -> Set<HKObjectType> {
    ensureSpecs()
    var types = Set<HKObjectType>()
    for spec in specs {
      types.insert(spec.objectType)
    }
    if let pressure = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) {
      types.insert(pressure)
    }
    return types
  }

  private static let quickTypeIds: Set<String> = [
    "heart_rate",
    "heart_rate_variability_sdnn",
    "oxygen_saturation",
    "step_count",
    "sleep_analysis",
    "workout",
    "respiratory_rate",
    "resting_heart_rate",
    "active_energy_burned",
  ]

  private static func buildSpecs() -> [SignalSpec] {
    var out: [SignalSpec] = []
    func addQuantity(_ raw: String) {
      guard let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: raw)) else { return }
      out.append(SignalSpec(typeId: snakeType(raw), kind: .quantity(type), objectType: type, sampleType: type))
    }
    func addCategory(_ raw: String) {
      guard let type = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: raw)) else { return }
      out.append(SignalSpec(typeId: snakeType(raw), kind: .category(type), objectType: type, sampleType: type))
    }
    func addCharacteristic(_ raw: String) {
      guard let type = HKCharacteristicType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: raw)) else { return }
      out.append(SignalSpec(typeId: snakeType(raw), kind: .characteristic(type), objectType: type, sampleType: nil))
    }

    let quantities = [
      "HKQuantityTypeIdentifierHeartRate",
      "HKQuantityTypeIdentifierRestingHeartRate",
      "HKQuantityTypeIdentifierWalkingHeartRateAverage",
      "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
      "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute",
      "HKQuantityTypeIdentifierAtrialFibrillationBurden",
      "HKQuantityTypeIdentifierOxygenSaturation",
      "HKQuantityTypeIdentifierRespiratoryRate",
      "HKQuantityTypeIdentifierVO2Max",
      "HKQuantityTypeIdentifierPeripheralPerfusionIndex",
      "HKQuantityTypeIdentifierStepCount",
      "HKQuantityTypeIdentifierDistanceWalkingRunning",
      "HKQuantityTypeIdentifierDistanceCycling",
      "HKQuantityTypeIdentifierDistanceWheelchair",
      "HKQuantityTypeIdentifierDistanceSwimming",
      "HKQuantityTypeIdentifierDistanceDownhillSnowSports",
      "HKQuantityTypeIdentifierDistanceCrossCountrySkiing",
      "HKQuantityTypeIdentifierDistancePaddleSports",
      "HKQuantityTypeIdentifierDistanceRowing",
      "HKQuantityTypeIdentifierPushCount",
      "HKQuantityTypeIdentifierSwimmingStrokeCount",
      "HKQuantityTypeIdentifierBasalEnergyBurned",
      "HKQuantityTypeIdentifierActiveEnergyBurned",
      "HKQuantityTypeIdentifierFlightsClimbed",
      "HKQuantityTypeIdentifierNikeFuel",
      "HKQuantityTypeIdentifierAppleExerciseTime",
      "HKQuantityTypeIdentifierAppleMoveTime",
      "HKQuantityTypeIdentifierAppleStandTime",
      "HKQuantityTypeIdentifierWalkingSpeed",
      "HKQuantityTypeIdentifierWalkingStepLength",
      "HKQuantityTypeIdentifierWalkingAsymmetryPercentage",
      "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
      "HKQuantityTypeIdentifierAppleWalkingSteadiness",
      "HKQuantityTypeIdentifierSixMinuteWalkTestDistance",
      "HKQuantityTypeIdentifierStairAscentSpeed",
      "HKQuantityTypeIdentifierStairDescentSpeed",
      "HKQuantityTypeIdentifierBodyMass",
      "HKQuantityTypeIdentifierBodyMassIndex",
      "HKQuantityTypeIdentifierBodyFatPercentage",
      "HKQuantityTypeIdentifierLeanBodyMass",
      "HKQuantityTypeIdentifierHeight",
      "HKQuantityTypeIdentifierWaistCircumference",
      "HKQuantityTypeIdentifierBodyTemperature",
      "HKQuantityTypeIdentifierBasalBodyTemperature",
      "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
      "HKQuantityTypeIdentifierElectrodermalActivity",
      "HKQuantityTypeIdentifierBloodPressureSystolic",
      "HKQuantityTypeIdentifierBloodPressureDiastolic",
      "HKQuantityTypeIdentifierBloodGlucose",
      "HKQuantityTypeIdentifierInsulinDelivery",
      "HKQuantityTypeIdentifierBloodAlcoholContent",
      "HKQuantityTypeIdentifierForcedVitalCapacity",
      "HKQuantityTypeIdentifierForcedExpiratoryVolume1",
      "HKQuantityTypeIdentifierPeakExpiratoryFlowRate",
      "HKQuantityTypeIdentifierInhalerUsage",
      "HKQuantityTypeIdentifierNumberOfTimesFallen",
      "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
      "HKQuantityTypeIdentifierHeadphoneAudioExposure",
      "HKQuantityTypeIdentifierEnvironmentalSoundReduction",
      "HKQuantityTypeIdentifierUvExposure",
      "HKQuantityTypeIdentifierTimeInDaylight",
      "HKQuantityTypeIdentifierUnderwaterDepth",
      "HKQuantityTypeIdentifierWaterTemperature",
      "HKQuantityTypeIdentifierRunningPower",
      "HKQuantityTypeIdentifierRunningSpeed",
      "HKQuantityTypeIdentifierRunningStrideLength",
      "HKQuantityTypeIdentifierRunningGroundContactTime",
      "HKQuantityTypeIdentifierRunningVerticalOscillation",
      "HKQuantityTypeIdentifierCyclingCadence",
      "HKQuantityTypeIdentifierCyclingPower",
      "HKQuantityTypeIdentifierCyclingSpeed",
      "HKQuantityTypeIdentifierCyclingFunctionalThresholdPower",
      "HKQuantityTypeIdentifierPhysicalEffort",
      "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore",
      "HKQuantityTypeIdentifierWorkoutEffortScore",
      "HKQuantityTypeIdentifierDietaryEnergyConsumed",
      "HKQuantityTypeIdentifierDietaryCarbohydrates",
      "HKQuantityTypeIdentifierDietaryProtein",
      "HKQuantityTypeIdentifierDietaryFatTotal",
      "HKQuantityTypeIdentifierDietaryFatSaturated",
      "HKQuantityTypeIdentifierDietaryCholesterol",
      "HKQuantityTypeIdentifierDietarySodium",
      "HKQuantityTypeIdentifierDietaryFiber",
      "HKQuantityTypeIdentifierDietarySugar",
      "HKQuantityTypeIdentifierDietaryWater",
      "HKQuantityTypeIdentifierDietaryCaffeine",
      "HKQuantityTypeIdentifierDietaryBiotin",
      "HKQuantityTypeIdentifierDietaryCalcium",
      "HKQuantityTypeIdentifierDietaryChloride",
      "HKQuantityTypeIdentifierDietaryChromium",
      "HKQuantityTypeIdentifierDietaryCopper",
      "HKQuantityTypeIdentifierDietaryFatMonounsaturated",
      "HKQuantityTypeIdentifierDietaryFatPolyunsaturated",
      "HKQuantityTypeIdentifierDietaryFolate",
      "HKQuantityTypeIdentifierDietaryIodine",
      "HKQuantityTypeIdentifierDietaryIron",
      "HKQuantityTypeIdentifierDietaryMagnesium",
      "HKQuantityTypeIdentifierDietaryManganese",
      "HKQuantityTypeIdentifierDietaryMolybdenum",
      "HKQuantityTypeIdentifierDietaryNiacin",
      "HKQuantityTypeIdentifierDietaryPantothenicAcid",
      "HKQuantityTypeIdentifierDietaryPhosphorus",
      "HKQuantityTypeIdentifierDietaryPotassium",
      "HKQuantityTypeIdentifierDietaryRiboflavin",
      "HKQuantityTypeIdentifierDietarySelenium",
      "HKQuantityTypeIdentifierDietaryThiamin",
      "HKQuantityTypeIdentifierDietaryVitaminA",
      "HKQuantityTypeIdentifierDietaryVitaminB6",
      "HKQuantityTypeIdentifierDietaryVitaminB12",
      "HKQuantityTypeIdentifierDietaryVitaminC",
      "HKQuantityTypeIdentifierDietaryVitaminD",
      "HKQuantityTypeIdentifierDietaryVitaminE",
      "HKQuantityTypeIdentifierDietaryVitaminK",
      "HKQuantityTypeIdentifierDietaryZinc",
      "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages",
      "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances",
    ]
    for raw in quantities { addQuantity(raw) }

    let categories = [
      "HKCategoryTypeIdentifierSleepAnalysis",
      "HKCategoryTypeIdentifierAppleStandHour",
      "HKCategoryTypeIdentifierMindfulSession",
      "HKCategoryTypeIdentifierHighHeartRateEvent",
      "HKCategoryTypeIdentifierLowHeartRateEvent",
      "HKCategoryTypeIdentifierIrregularHeartRhythmEvent",
      "HKCategoryTypeIdentifierLowCardioFitnessEvent",
      "HKCategoryTypeIdentifierAudioExposureEvent",
      "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent",
      "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent",
      "HKCategoryTypeIdentifierToothbrushingEvent",
      "HKCategoryTypeIdentifierHandwashingEvent",
      "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent",
      "HKCategoryTypeIdentifierMenstrualFlow",
      "HKCategoryTypeIdentifierIntermenstrualBleeding",
      "HKCategoryTypeIdentifierInfrequentMenstrualCycles",
      "HKCategoryTypeIdentifierIrregularMenstrualCycles",
      "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding",
      "HKCategoryTypeIdentifierProlongedMenstrualPeriods",
      "HKCategoryTypeIdentifierCervicalMucusQuality",
      "HKCategoryTypeIdentifierOvulationTestResult",
      "HKCategoryTypeIdentifierProgesteroneTestResult",
      "HKCategoryTypeIdentifierPregnancy",
      "HKCategoryTypeIdentifierPregnancyTestResult",
      "HKCategoryTypeIdentifierLactation",
      "HKCategoryTypeIdentifierContraceptive",
      "HKCategoryTypeIdentifierSexualActivity",
      "HKCategoryTypeIdentifierBleedingAfterPregnancy",
      "HKCategoryTypeIdentifierBleedingDuringPregnancy",
      "HKCategoryTypeIdentifierAbdominalCramps",
      "HKCategoryTypeIdentifierAcne",
      "HKCategoryTypeIdentifierAppetiteChanges",
      "HKCategoryTypeIdentifierBladderIncontinence",
      "HKCategoryTypeIdentifierBloating",
      "HKCategoryTypeIdentifierBreastPain",
      "HKCategoryTypeIdentifierChestTightnessOrPain",
      "HKCategoryTypeIdentifierChills",
      "HKCategoryTypeIdentifierConstipation",
      "HKCategoryTypeIdentifierCoughing",
      "HKCategoryTypeIdentifierDiarrhea",
      "HKCategoryTypeIdentifierDizziness",
      "HKCategoryTypeIdentifierDrySkin",
      "HKCategoryTypeIdentifierFainting",
      "HKCategoryTypeIdentifierFatigue",
      "HKCategoryTypeIdentifierFever",
      "HKCategoryTypeIdentifierGeneralizedBodyAche",
      "HKCategoryTypeIdentifierHairLoss",
      "HKCategoryTypeIdentifierHeadache",
      "HKCategoryTypeIdentifierHeartburn",
      "HKCategoryTypeIdentifierHotFlashes",
      "HKCategoryTypeIdentifierLossOfSmell",
      "HKCategoryTypeIdentifierLossOfTaste",
      "HKCategoryTypeIdentifierLowerBackPain",
      "HKCategoryTypeIdentifierMemoryLapse",
      "HKCategoryTypeIdentifierMoodChanges",
      "HKCategoryTypeIdentifierNausea",
      "HKCategoryTypeIdentifierNightSweats",
      "HKCategoryTypeIdentifierPelvicPain",
      "HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat",
      "HKCategoryTypeIdentifierRunnyNose",
      "HKCategoryTypeIdentifierShortnessOfBreath",
      "HKCategoryTypeIdentifierSinusCongestion",
      "HKCategoryTypeIdentifierSkippedHeartbeat",
      "HKCategoryTypeIdentifierSleepChanges",
      "HKCategoryTypeIdentifierSoreThroat",
      "HKCategoryTypeIdentifierVaginalDryness",
      "HKCategoryTypeIdentifierVomiting",
      "HKCategoryTypeIdentifierWheezing",
    ]
    for raw in categories { addCategory(raw) }

    for raw in [
      "HKCharacteristicTypeIdentifierBiologicalSex",
      "HKCharacteristicTypeIdentifierBloodType",
      "HKCharacteristicTypeIdentifierDateOfBirth",
      "HKCharacteristicTypeIdentifierFitzpatrickSkinType",
      "HKCharacteristicTypeIdentifierWheelchairUse",
      "HKCharacteristicTypeIdentifierActivityMoveMode",
    ] {
      addCharacteristic(raw)
    }

    let workout = HKWorkoutType.workoutType()
    out.append(SignalSpec(typeId: "workout", kind: .workout, objectType: workout, sampleType: workout))
    let heartbeat = HKSeriesType.heartbeat()
    out.append(SignalSpec(
      typeId: "heartbeat_series",
      kind: .sample(heartbeat, "心跳序列"),
      objectType: heartbeat,
      sampleType: heartbeat
    ))
    let route = HKSeriesType.workoutRoute()
    out.append(SignalSpec(
      typeId: "workout_route",
      kind: .sample(route, "锻炼路线"),
      objectType: route,
      sampleType: route
    ))
    if #available(iOS 14.0, *) {
      let ecg = HKObjectType.electrocardiogramType()
      out.append(SignalSpec(
        typeId: "electrocardiogram",
        kind: .sample(ecg, "心电图"),
        objectType: ecg,
        sampleType: ecg
      ))
    }
    let audio = HKObjectType.audiogramSampleType()
    out.append(SignalSpec(
      typeId: "audiogram",
      kind: .sample(audio, "听力图"),
      objectType: audio,
      sampleType: audio
    ))
    let activity = HKObjectType.activitySummaryType()
    out.append(SignalSpec(
      typeId: "activity_summary",
      kind: .activitySummary,
      objectType: activity,
      sampleType: nil
    ))
    if #available(iOS 16.0, *) {
      let vision = HKObjectType.visionPrescriptionType()
      out.append(SignalSpec(
        typeId: "vision_prescription",
        kind: .sample(vision, "视力处方"),
        objectType: vision,
        sampleType: vision
      ))
    }
    if #available(iOS 18.0, *) {
      let mind = HKObjectType.stateOfMindType()
      out.append(SignalSpec(
        typeId: "state_of_mind",
        kind: .sample(mind, "状态"),
        objectType: mind,
        sampleType: mind
      ))
    }
    if #available(iOS 26.0, *) {
      let medication = HKObjectType.userAnnotatedMedicationType()
      if let sample = medication as? HKSampleType {
        out.append(SignalSpec(
          typeId: "user_annotated_medication",
          kind: .sample(sample, "用药记录"),
          objectType: medication,
          sampleType: sample
        ))
      } else {
        out.append(SignalSpec(
          typeId: "user_annotated_medication",
          kind: .authorizeOnly,
          objectType: medication,
          sampleType: nil
        ))
      }
    }
    return out
  }

  /// `HKQuantityTypeIdentifierVO2Max` → `vo2_max`。
  private static func snakeType(_ raw: String) -> String {
    let prefixes = [
      "HKQuantityTypeIdentifier",
      "HKCategoryTypeIdentifier",
      "HKCharacteristicTypeIdentifier",
      "HKCorrelationTypeIdentifier",
    ]
    var name = raw
    for prefix in prefixes where name.hasPrefix(prefix) {
      name.removeFirst(prefix.count)
      break
    }
    if name == "VO2Max" { return "vo2_max" }
    var spaced = name
    if let regex = try? NSRegularExpression(pattern: "([A-Z]+)([A-Z][a-z])") {
      spaced = regex.stringByReplacingMatches(
        in: spaced,
        range: NSRange(spaced.startIndex..., in: spaced),
        withTemplate: "$1_$2"
      )
    }
    if let regex = try? NSRegularExpression(pattern: "([a-z0-9])([A-Z])") {
      spaced = regex.stringByReplacingMatches(
        in: spaced,
        range: NSRange(spaced.startIndex..., in: spaced),
        withTemplate: "$1_$2"
      )
    }
    return spaced.lowercased()
  }
}

private struct PendingAccess {
  let result: FlutterResult
  let requested: Int
}

private final class ImportJob {
  let untilMs: Int
  let defaultSinceMs: Int
  let sinceByType: [String: Int]
  let intervalMs: Int
  let phaseMs: Int
  let quick: Bool
  let trigger: String?
  let done: (() -> Void)?
  private let completion: (() -> Void)?
  private let lock = NSLock()
  private var completed = false

  init(
    untilMs: Int,
    defaultSinceMs: Int,
    sinceByType: [String: Int],
    intervalMs: Int,
    phaseMs: Int,
    quick: Bool,
    trigger: String?,
    completion: (() -> Void)?,
    done: (() -> Void)?
  ) {
    self.untilMs = untilMs
    self.defaultSinceMs = defaultSinceMs
    self.sinceByType = sinceByType
    self.intervalMs = intervalMs
    self.phaseMs = phaseMs
    self.quick = quick
    self.trigger = trigger
    self.completion = completion
    self.done = done
  }

  func callCompletion() {
    lock.lock()
    let should = !completed
    completed = true
    lock.unlock()
    if should { completion?() }
  }
}

private struct SignalSpec {
  enum Kind {
    case quantity(HKQuantityType)
    case category(HKCategoryType)
    case characteristic(HKCharacteristicType)
    case workout
    case activitySummary
    case sample(HKSampleType, String)
    case authorizeOnly
  }

  let typeId: String
  let kind: Kind
  let objectType: HKObjectType
  let sampleType: HKSampleType?
}
