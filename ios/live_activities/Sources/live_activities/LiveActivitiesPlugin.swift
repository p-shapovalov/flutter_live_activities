import ActivityKit
import Flutter
import UIKit
import Foundation
import CryptoKit

@available(iOS 16.1, *)
class FlutterAlertConfig {
  let _title:String
  let _body:String
  let _sound:String?

  init(title:String, body:String, sound:String?) {
    _title = title;
    _body = body;
    _sound = sound;
  }

  func getAlertConfig() -> AlertConfiguration {
      return AlertConfiguration(title: LocalizedStringResource(stringLiteral: _title), body: LocalizedStringResource(stringLiteral: _body), sound: (_sound == nil) ? .default : AlertConfiguration.AlertSound.named(_sound!));
  }
}

public class LiveActivitiesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var urlSchemeSink: FlutterEventSink?
  private var appGroupId: String?
  private var urlScheme: String?
  private var sharedDefault: UserDefaults?
  private var appLifecycleLiveActivityIds = [String]()
  private var activityEventSink: FlutterEventSink?
  private var pushToStartTokenEventSink: FlutterEventSink?
  // System UUIDs of activities the plugin has already attached observers to.
  // Prevents double-monitoring when an activity is seen via both the initial
  // `Activity.activities` snapshot and the `Activity.activityUpdates` stream.
  private var monitoredActivities = Set<String>()
  // System UUIDs of activities for which a `pushTokenUpdates` Task is running.
  // Without this dedup, every `.active` transition starts another parallel
  // observer Task that all emit the same token rotations.
  private var tokenMonitoredActivities = Set<String>()
  private var didStartObservingActivities = false
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "live_activities", binaryMessenger: registrar.messenger())
    let urlSchemeChannel = FlutterEventChannel(name: "live_activities/url_scheme", binaryMessenger: registrar.messenger())
    let activityStatusChannel = FlutterEventChannel(name: "live_activities/activity_status", binaryMessenger: registrar.messenger())
    let pushToStartTokenUpdatesChannel = FlutterEventChannel(name: "live_activities/push_to_start_token_updates", binaryMessenger: registrar.messenger())
    
    let instance = LiveActivitiesPlugin()
    
    registrar.addMethodCallDelegate(instance, channel: channel)
    urlSchemeChannel.setStreamHandler(instance)
    activityStatusChannel.setStreamHandler(instance)
    pushToStartTokenUpdatesChannel.setStreamHandler(instance)
    registrar.addApplicationDelegate(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    urlSchemeSink = nil
    activityEventSink = nil
    pushToStartTokenEventSink = nil
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    if let args = arguments as? String{
      if (args == "urlSchemeStream") {
        urlSchemeSink = events
      } else if (args == "activityUpdateStream") {
        activityEventSink = events
      } else if (args == "pushToStartTokenUpdateStream") {
        pushToStartTokenEventSink = events
        startObservingPushToStartTokens()
      }
    }

    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let args = arguments as? String{
      if (args == "urlSchemeStream") {
        urlSchemeSink = nil
      } else if (args == "activityUpdateStream") {
        activityEventSink = nil
      } else if (args == "pushToStartTokenUpdateStream") {
         pushToStartTokenEventSink = nil
       }
    }
    return nil
  }
  
  private func initializationGuard(result: @escaping FlutterResult) {
    if self.appGroupId == nil || self.sharedDefault == nil {
      result(FlutterError(code: "NEED_INIT", message: "you need to run 'init()' first with app group id to create live activity", details: nil))
    }
  }
  
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if (call.method == "areActivitiesSupported") {
       guard #available(iOS 16.1, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
          result(false)
          return
      }
      result(true)
      return
    }

    if (call.method == "areActivitiesEnabled") {
      guard #available(iOS 16.1, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
          result(false)
          return
      }
      
      result(ActivityAuthorizationInfo().areActivitiesEnabled)
      return
    }

    if (call.method == "allowsPushStart") {
      guard #available(iOS 17.2, *), !ProcessInfo.processInfo.isiOSAppOnMac else {
          result(false)
          return
      }

      // This is iOS 17.2+ so push-to-start is supported
      result(true)
      return
    }
    
    if #available(iOS 16.1, *) {
      switch call.method {
        case "init":
          guard let args = call.arguments as? [String: Any] else {
            return
          }

          self.urlScheme = args["urlScheme"] as? String;

          if let appGroupId = args["appGroupId"] as? String {
            self.appGroupId = appGroupId
            sharedDefault = UserDefaults(suiteName: self.appGroupId)!
            startObservingActivities()
            result(nil)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'appGroupId' is valid", details: nil))
          }

          break
        case "createActivity":
          initializationGuard(result: result)
          guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
            return
          }

           if let data = args["data"] as? [String: Any], let activityId = args["activityId"] as? String? ?? nil {
            let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? false
            let staleIn = args["staleIn"] as? Int? ?? nil
            createActivity(data: data, removeWhenAppIsKilled: removeWhenAppIsKilled, staleIn: staleIn, activityId: activityId, result: result)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'data' is valid", details: nil))
          }
          break
        case "updateActivity":
          initializationGuard(result: result)
          guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
            return
          }
          if let activityId = args["activityId"] as? String, let data = args["data"] as? [String: Any] {
              let alertConfigMap = args["alertConfig"] as? [String:String?];
              let alertTitle = alertConfigMap?["title"] as? String;
              let alertBody = alertConfigMap?["body"] as? String;
              let alertSound = alertConfigMap?["sound"] as? String;

              let alertConfig = (alertTitle == nil || alertBody == nil) ? nil : FlutterAlertConfig(title: alertTitle!, body: alertBody!, sound: alertSound);

            updateActivity(activityId: activityId, data: data, alertConfig: alertConfig, result: result)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId', 'data' are valid", details: nil))
          }
          break
        case "endActivity":
          guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
            return
          }
          if let activityId = args["activityId"] as? String {
            endActivity(activityId: activityId, result: result)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
          }
          break
        case "getActivityState":
          guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
            return
          }
          if let activityId = args["activityId"] as? String {
            getActivityState(activityId: activityId, result: result)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
          }
          break
        case "getPushToken":
          guard let args = call.arguments  as? [String: Any] else {
            return
          }
          if let activityId = args["activityId"] as? String {
            getPushToken(activityId: activityId, result: result)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'activityId' is valid", details: nil))
          }
          break
        case "getAllActivitiesIds":
          getAllActivitiesIds(result: result)
          break
        case "getAllActivities":
          getAllActivities(result: result)
          break
        case "endAllActivities":
          endAllActivities(result: result)
          break
        case "createOrUpdateActivity":
          initializationGuard(result: result)
          guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "WRONG_ARGS", message: "Unknown data type in argument", details: nil))
            return
          }

          if let data = args["data"] as? [String: Any], let activityId = args["activityId"] as? String {
            let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? false
            let staleIn = args["staleIn"] as? Int? ?? nil
            createOrUpdateActivity(data: data, activityId: activityId, removeWhenAppIsKilled: removeWhenAppIsKilled, staleIn: staleIn, result: result)
          } else {
            result(FlutterError(code: "WRONG_ARGS", message: "argument are not valid, check if 'data', 'activityId' is valid", details: nil))
          }
          break
        default:
          break
      }
    } else {
      result(FlutterError(code: "WRONG_IOS_VERSION", message: "this version of iOS is not supported", details: nil))
    }
  }
  
  @available(iOS 16.1, *)
  func createActivity(data: [String: Any], removeWhenAppIsKilled: Bool, staleIn: Int?, activityId: String? = nil, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      if let error = error {
        result(FlutterError(code: "AUTHORIZATION_ERROR", message: "authorization error", details: error.localizedDescription))
      }
    }
    
    let liveDeliveryAttributes: LiveActivityAppsAttributes
    if let activityId = activityId {
        liveDeliveryAttributes = LiveActivityAppsAttributes(id: activityId)
    } else {
        liveDeliveryAttributes = LiveActivityAppsAttributes()
    }
    // Dynamic content lives in shared UserDefaults; the widget reads it via
    // the appGroupId carried in ContentState.
    let initialContentState = LiveActivityAppsAttributes.LiveDeliveryData(appGroupId: appGroupId!)
    var deliveryActivity: Activity<LiveActivityAppsAttributes>?
    let prefix = liveDeliveryAttributes.id

    for item in data {
        sharedDefault!.set(item.value, forKey: "\(prefix)_\(item.key)")
    }

    if #available(iOS 16.2, *){
      let activityContent = ActivityContent(
        state: initialContentState,
        staleDate: staleIn != nil ? Calendar.current.date(byAdding: .minute, value: staleIn!, to: Date.now) : nil)
      do {
        deliveryActivity = try Activity.request(
          attributes: liveDeliveryAttributes,
          content: activityContent,
          pushType: .token)
      } catch (let error) {
        result(FlutterError(code: "LIVE_ACTIVITY_ERROR", message: "can't launch live activity", details: error.localizedDescription))
      }
    } else {
      do {
        deliveryActivity = try Activity<LiveActivityAppsAttributes>.request(
          attributes: liveDeliveryAttributes,
          contentState: initialContentState,
          pushType: .token)
        
      } catch (let error) {
        result(FlutterError(code: "LIVE_ACTIVITY_ERROR", message: "can't launch live activity", details: error.localizedDescription))
      }
    }
    if (deliveryActivity != nil) {
      if removeWhenAppIsKilled {
          appLifecycleLiveActivityIds.append(deliveryActivity!.attributes.id)
      }
      // Track via the dedup set so the activityUpdates stream doesn't double-attach.
      monitoredActivities.insert(deliveryActivity!.id)
      monitorLiveActivity(deliveryActivity!)
        result(deliveryActivity!.attributes.id)
    }
  }
  
  @available(iOS 16.1, *)
  func updateActivity(activityId: String, data: [String: Any?], alertConfig: FlutterAlertConfig?, result: @escaping FlutterResult) {
    Task {
        let activities = await MainActor.run { Activity<LiveActivityAppsAttributes>.activities }
        guard let activity = activities.first(where: { $0.attributes.id == activityId }) else {
            result(FlutterError(code: "ACTIVITY_ERROR", message: "Activity not found", details: nil))
            return
        }

          let prefix = activity.attributes.id

        await MainActor.run {
            for (key, value) in data {
                if let value = value, !(value is NSNull) {
                    sharedDefault?.set(value, forKey: "\(prefix)_\(key)")
            } else {
                    sharedDefault?.removeObject(forKey: "\(prefix)_\(key)")
                }
            }
          }
          
          let updatedStatus = LiveActivityAppsAttributes.LiveDeliveryData(appGroupId: self.appGroupId!)
          await activity.update(using: updatedStatus, alertConfiguration: alertConfig?.getAlertConfig())

      result(nil)
    }
  }

  @available(iOS 16.1, *)
  func createOrUpdateActivity(data: [String: Any], activityId: String, removeWhenAppIsKilled: Bool, staleIn: Int?, result: @escaping FlutterResult) {
    Task {
        var activities: [Activity<LiveActivityAppsAttributes>] = []
        for _ in 0..<3 { // Try up to 3 times
            activities = await MainActor.run { Activity<LiveActivityAppsAttributes>.activities }
            if !activities.isEmpty {
                break
            }
            try? await Task.sleep(for: .seconds(0.1))
        }

        let existingActivity = activities.first {
          $0.attributes.id == activityId && $0.activityState != .dismissed && $0.activityState != .ended
        }

        if let activityId = existingActivity?.attributes.id {
            updateActivity(activityId: activityId, data: data, alertConfig: nil, result: result)
      } else {
        createActivity(data: data, removeWhenAppIsKilled: removeWhenAppIsKilled, staleIn: staleIn, activityId: activityId, result: result)
      }
    }
  }

  @available(iOS 16.1, *)
  func getActivityState(activityId: String, result: @escaping FlutterResult) {
    Task {
      if let matchingActivity = Activity<LiveActivityAppsAttributes>.activities.first(where: { $0.attributes.id == activityId }) {
        var state = activityStateToString(activityState: matchingActivity.activityState)
        result(state)
      } else {
        // No matching activity was found
        result(nil)
      }
    }
  }
  
  @available(iOS 16.1, *)
  func getPushToken(activityId: String, result: @escaping FlutterResult) {
    Task {
      var pushToken: String?;
      for activity in Activity<LiveActivityAppsAttributes>.activities {
          if (activityId == activity.attributes.id) {
          if let data = activity.pushToken {
            pushToken = data.map { String(format: "%02x", $0) }.joined()
          }
        }
      }
      result(pushToken)
    }
  }

  @available(iOS 16.1, *)
  func endActivity(activityId: String, result: @escaping FlutterResult) {
    appLifecycleLiveActivityIds.removeAll { $0 == activityId }
    Task {
      await endActivitiesWithId(activityIds: [activityId])
      result(nil)
    }
  }
  
  @available(iOS 16.1, *)
  func endAllActivities(result: @escaping FlutterResult) {
    Task {
      for activity in Activity<LiveActivityAppsAttributes>.activities {
        await activity.end(dismissalPolicy: .immediate)
      }
      appLifecycleLiveActivityIds.removeAll()
      result(nil)
    }
  }

  private func startObservingPushToStartTokens() {
    if #available(iOS 17.2, *) {
      NSLog("[LA Plugin] startObservingPushToStartTokens: subscribing to pushToStartTokenUpdates")
      Task {
        for await data in Activity<LiveActivityAppsAttributes>.pushToStartTokenUpdates {
          let token = data.map { String(format: "%02x", $0) }.joined()
          NSLog("[LA Plugin] pushToStartTokenUpdate received token=\(token.prefix(8))... (\(data.count) bytes)")
          DispatchQueue.main.async {
            self.pushToStartTokenEventSink?(token)
          }
        }
        NSLog("[LA Plugin] pushToStartTokenUpdates stream ended")
      }
    } else {
      NSLog("[LA Plugin] startObservingPushToStartTokens: iOS < 17.2, push-to-start unsupported")
    }
  }

  // Monitors all live activities — those created via the plugin AND those
  // launched by iOS in response to a push-to-start payload. Without this,
  // push-to-start activities are invisible to `activityUpdateStream` because
  // `monitorLiveActivity` is otherwise only attached from `createActivity`.
  @available(iOS 16.1, *)
  private func startObservingActivities() {
    if didStartObservingActivities {
      NSLog("[LA Plugin] startObservingActivities: already started, skipping")
      return
    }
    didStartObservingActivities = true

    let existing = Activity<LiveActivityAppsAttributes>.activities
    NSLog("[LA Plugin] startObservingActivities: \(existing.count) existing activities at init")
    for activity in existing {
      NSLog("[LA Plugin]   existing activity sysId=\(activity.id) attrs.id=\(activity.attributes.id) state=\(activityStateToString(activityState: activity.activityState))")
      monitorIfNeeded(activity)
    }

    if #available(iOS 16.2, *) {
      NSLog("[LA Plugin] subscribing to Activity.activityUpdates")
      Task {
        for await activity in Activity<LiveActivityAppsAttributes>.activityUpdates {
          NSLog("[LA Plugin] activityUpdates fired: sysId=\(activity.id) attrs.id=\(activity.attributes.id) state=\(self.activityStateToString(activityState: activity.activityState))")
          self.monitorIfNeeded(activity)
        }
        NSLog("[LA Plugin] activityUpdates stream ended")
      }
    }
  }

  @available(iOS 16.1, *)
  private func monitorIfNeeded(_ activity: Activity<LiveActivityAppsAttributes>) {
    if monitoredActivities.contains(activity.id) {
      NSLog("[LA Plugin] monitorIfNeeded: sysId=\(activity.id) already monitored")
      return
    }
    NSLog("[LA Plugin] monitorIfNeeded: starting monitor for sysId=\(activity.id) attrs.id=\(activity.attributes.id)")
    monitoredActivities.insert(activity.id)
    monitorLiveActivity(activity)
  }

  @available(iOS 16.1, *)
  func getAllActivitiesIds(result: @escaping FlutterResult) {
    var activitiesId: [String] = []
    for activity in Activity<LiveActivityAppsAttributes>.activities {
        activitiesId.append(activity.attributes.id)
    }
    result(activitiesId)
  }

  @available(iOS 16.1, *)
  func getAllActivities(result: @escaping FlutterResult) {
    var activitiesState: [String: String] = [:]
    let all = Activity<LiveActivityAppsAttributes>.activities
    NSLog("[LA Plugin] getAllActivities: \(all.count) total")
    for activity in all {
      let stateStr = activityStateToString(activityState: activity.activityState)
      NSLog("[LA Plugin]   sysId=\(activity.id) attrs.id=\(activity.attributes.id) state=\(stateStr) hasToken=\(activity.pushToken != nil)")
      activitiesState[activity.attributes.id] = stateStr
    }
    result(activitiesState)
  }
  
  @available(iOS 16.1, *)
  private func endActivitiesWithId(activityIds: [String]) async {
    for activity in Activity<LiveActivityAppsAttributes>.activities {
      for id in activityIds {
        if id == activity.attributes.id {
          await activity.end(dismissalPolicy: .immediate)
          break
        }
      }
    }
  }
  
  public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    
    if components?.scheme == nil || components?.scheme != urlScheme { return false }
    
    var queryResult: Dictionary<String, Any> = Dictionary()
    
    queryResult["queryItems"] = components?.queryItems?.map({ (item) -> Dictionary<String, String> in
      var queryItemResult: Dictionary<String, String> = Dictionary()
      queryItemResult["name"] = item.name
      queryItemResult["value"] = item.value
      return queryItemResult
    })
    queryResult["scheme"] = components?.scheme
    queryResult["host"] = components?.host
    queryResult["path"] = components?.path
    queryResult["url"] = components?.url?.absoluteString
    
    urlSchemeSink?.self(queryResult)
    return true
  }
  
  public func applicationWillTerminate(_ application: UIApplication) {
    if #available(iOS 16.1, *) {
      Task {
        await self.endActivitiesWithId(activityIds: self.appLifecycleLiveActivityIds)
      }
    }
  }
  
  // Must structurally match `LiveActivityAppsAttributes` declared in the
  // widget extension. iOS identifies the activity attributes type by its
  // unqualified name across compilation units, and the Codable shape on
  // both sides must tolerate the same payloads (so backend push-to-start
  // payloads and locally-created activities round-trip cleanly).
  struct LiveActivityAppsAttributes: ActivityAttributes, Identifiable {
    public typealias LiveDeliveryData = ContentState

    public struct ContentState: Codable, Hashable {
      var appGroupId: String = ""

      init(appGroupId: String = "") {
        self.appGroupId = appGroupId
      }

      // Lenient decoder so a payload missing `appGroupId` (e.g. backend's
      // push-to-start content-state, which carries the widget's fields like
      // `deviceId`/`statusText` instead) doesn't fail with NSCocoaErrorDomain
      // 4865. Swift's auto-synthesized decoder ignores property defaults, so
      // we have to write this explicitly.
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appGroupId = try c.decodeIfPresent(String.self, forKey: .appGroupId) ?? ""
      }
    }

    var id: String = ""

    init(id: String = "") {
      self.id = id
    }
  }
  
  @available(iOS 16.1, *)
  private func monitorLiveActivity(_ activity: Activity<LiveActivityAppsAttributes>) {
    Task {
      for await state in activity.activityStateUpdates {
        let stateStr = self.activityStateToString(activityState: state)
        NSLog("[LA Plugin] state change: sysId=\(activity.id) attrs.id=\(activity.attributes.id) -> \(stateStr)")
        switch state {
        case .active:
          if let data = activity.pushToken {
            let pushToken = data.map { String(format: "%02x", $0) }.joined()
            NSLog("[LA Plugin]   active with token=\(pushToken.prefix(8))... (immediate emit)")
            DispatchQueue.main.async {
              var response: Dictionary<String, Any> = Dictionary()
              response["token"] = pushToken
              response["activityId"] = activity.attributes.id
              response["status"] = "active"
              self.activityEventSink?.self(response)
            }
          } else {
            NSLog("[LA Plugin]   active but pushToken is nil — will poll")
          }
          monitorTokenChanges(activity)
        case .dismissed, .ended:
          NSLog("[LA Plugin]   removing from monitored set")
          self.monitoredActivities.remove(activity.id)
          self.lastEmittedToken.removeValue(forKey: activity.id)
          DispatchQueue.main.async {
              var response: Dictionary<String, Any> = Dictionary()
              response["activityId"] = activity.attributes.id
              response["status"] = "ended"
              self.activityEventSink?.self(response)
          }
        case .stale:
          DispatchQueue.main.async {
              var response: Dictionary<String, Any> = Dictionary()
              response["activityId"] = activity.attributes.id
              response["status"] = "stale"
              self.activityEventSink?.self(response)
          }
        @unknown default:
          DispatchQueue.main.async {
              var response: Dictionary<String, Any> = Dictionary()
              response["activityId"] = activity.attributes.id
              response["status"] = "unknown"
              self.activityEventSink?.self(response)
          }
        }
      }
      NSLog("[LA Plugin] activityStateUpdates stream ended for sysId=\(activity.id)")
    }
  }
  
  @available(iOS 16.1, *)
  private func monitorTokenChanges(_ activity: Activity<LiveActivityAppsAttributes>) {
    if tokenMonitoredActivities.contains(activity.id) {
      NSLog("[LA Plugin] monitorTokenChanges: sysId=\(activity.id) already monitored")
      return
    }
    tokenMonitoredActivities.insert(activity.id)
    NSLog("[LA Plugin] monitorTokenChanges: sysId=\(activity.id) — starting stream + poll")

    Task {
      for await data in activity.pushTokenUpdates {
        self.emitTokenIfChanged(activity, data: data, source: "stream")
      }
      NSLog("[LA Plugin] pushTokenUpdates stream ended for sysId=\(activity.id)")
      self.tokenMonitoredActivities.remove(activity.id)
    }

    let sysId = activity.id
    Task {
      let intervalNs: UInt64 = 1_500_000_000 // 1.5s
      let maxAttempts = 60                   // ~90s total
      for attempt in 1...maxAttempts {
        try? await Task.sleep(nanoseconds: intervalNs)
        guard let current = Activity<LiveActivityAppsAttributes>.activities.first(where: { $0.id == sysId }) else {
          NSLog("[LA Plugin] poll: sysId=\(sysId) gone from Activity.activities at attempt \(attempt)")
          return
        }
        let state = current.activityState
        if state == .ended || state == .dismissed {
          NSLog("[LA Plugin] poll: sysId=\(sysId) ended/dismissed at attempt \(attempt)")
          return
        }
        if let data = current.pushToken {
          NSLog("[LA Plugin] poll: sysId=\(sysId) got token at attempt \(attempt)")
          self.emitTokenIfChanged(current, data: data, source: "poll")
          return
        }
      }
      NSLog("[LA Plugin] poll: sysId=\(sysId) timed out after \(maxAttempts) attempts with no token")
    }
  }

  // Token cache to dedupe between the AsyncSequence and the polling Task.
  // sysId → last hex token emitted.
  private var lastEmittedToken: [String: String] = [:]

  @available(iOS 16.1, *)
  private func emitTokenIfChanged(_ activity: Activity<LiveActivityAppsAttributes>, data: Data, source: String) {
    let pushToken = data.map { String(format: "%02x", $0) }.joined()
    if lastEmittedToken[activity.id] == pushToken {
      NSLog("[LA Plugin] emitToken[\(source)]: sysId=\(activity.id) token unchanged, skipping")
      return
    }
    NSLog("[LA Plugin] emitToken[\(source)]: sysId=\(activity.id) attrs.id=\(activity.attributes.id) token=\(pushToken.prefix(8))...")
    lastEmittedToken[activity.id] = pushToken
    DispatchQueue.main.async {
      var response: Dictionary<String, Any> = Dictionary()
      response["token"] = pushToken
      response["activityId"] = activity.attributes.id
      response["status"] = "active"
      self.activityEventSink?.self(response)
    }
  }

  @available(iOS 16.1, *)
  private func activityStateToString(activityState: ActivityState) -> String {
      switch activityState {
      case .active:
          return "active"
      case .ended:
          return "ended"
      case .dismissed:
          return "dismissed"
      case .stale:
          return "stale"
      @unknown default:
          return "unknown"
      }
  }

}
