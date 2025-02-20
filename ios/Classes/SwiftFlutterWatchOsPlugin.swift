import Flutter
import UIKit
import WatchConnectivity
import Foundation
import HealthKit

typealias ReplyHandler = ([String: Any]) -> Void
typealias ProgressHandler = (Int) -> Void

public class SwiftFlutterWatchOsConnectivityPlugin: NSObject, FlutterPlugin {
    private var watchSession: WCSession?
    private var callbackChannel: FlutterMethodChannel
    private var fileProgressTimers: [String: Timer] = [:]
    
    private var messageReplyHandlers: [String: ([String : Any]) -> Void] = [:]
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "sstonn/flutter_watch_os_connectivity", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterWatchOsConnectivityPlugin(callbackChannel: FlutterMethodChannel(name: "sstonn/flutter_watch_os_connectivity_callback", binaryMessenger: registrar.messenger()))
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    init(callbackChannel: FlutterMethodChannel) {
        self.callbackChannel = callbackChannel
        if WCSession.isSupported() {
            watchSession = WCSession.default
        } else {
            watchSession = nil
        }
        super.init()
        watchSession?.delegate = self
        watchSession?.activate()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            let isSupported = WCSession.isSupported()
            result(isSupported)
            
        case "getActivateState":
            checkForWatchSession(result: result)
            result(watchSession?.activationState.rawValue)
            
        case "getPairedDeviceInfo":
            checkForWatchSession(result: result)
            do {
                result(try watchSession?.toPairedDeviceJsonString())
            } catch {
                handleFlutterError(result: result, message: error.localizedDescription)
            }
            
        case "getReachability":
            checkForWatchSession(result: result)
            result(watchSession!.isReachable)
            
        case "sendMessage":
            checkForWatchSession(result: result)
            if let arguments = call.arguments as? [String: Any] {
                checkSessionReachability(result: result)
                if let message = arguments["message"] as? [String: Any] {
                    var handler: ReplyHandler? = nil
                    if let replyHandlerId = arguments["replyHandlerId"] as? String {
                        handler = { replyHandler in
                            var arguments: [String: Any] = [:]
                            arguments["replyMessage"] = replyHandler
                            arguments["replyHandlerId"] = replyHandlerId
                            self.callbackChannel.invokeMethod("onMessageReplied", arguments: arguments)
                        }
                    }
                    watchSession?.sendMessage(message, replyHandler: handler) { error in
                        self.handleFlutterError(result: result, message: error.localizedDescription)
                    }
                }
                
            }
            result(nil)
            
        case "replyMessage":
            checkForWatchSession(result: result)
            if let arguments = call.arguments as? [String: Any] {
                checkSessionReachability(result: result)
                if let message = arguments["replyMessage"] as? [String: Any],
                   let replyHandlerId = arguments["replyHandlerId"] as? String,
                   let replyHandler =  messageReplyHandlers[replyHandlerId] {
                    replyHandler(message)
                    messageReplyHandlers.removeValue(forKey: replyHandlerId)
                }
            }
            result(nil)
            
        case "getLatestApplicationContext":
            checkForWatchSession(result: result)
            result(getApplicationContext(session: watchSession!))
            
        case "updateApplicationContext":
            checkForWatchSession(result: result)
            if let sentApplicationContext = call.arguments as? [String: Any] {
                do {
                    try watchSession?.updateApplicationContext(sentApplicationContext)
                    self.callbackChannel.invokeMethod("onApplicationContextUpdated", arguments: getApplicationContext(session: self.watchSession!))
                } catch {
                    handleFlutterError(result: result, message: error.localizedDescription)
                }
            }
            result(nil)
            
        case "transferUserInfo":
            checkForWatchSession(result: result)
            if let arguments = call.arguments as? [String: Any],
               let userInfo = arguments["userInfo"] as? [String: Any],
               let isComplication = arguments["isComplication"] as? Bool {
                let userInfoTransfer = isComplication ? watchSession!.transferCurrentComplicationUserInfo(userInfo) : watchSession!.transferUserInfo(userInfo)
                self.callbackChannel.invokeMethod("onPendingUserInfoTransferListChanged", arguments: self.watchSession?.outstandingUserInfoTransfers.map{ $0.toRawTransferDict() })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
                    result(userInfoTransfer.toRawTransferDict())
                })
                return
                
            }
            result(nil)
            
        case "getOnProgressUserInfoTransfers":
            checkForWatchSession(result: result)
            result(watchSession!.outstandingUserInfoTransfers.map{ $0.toRawTransferDict() })
            
        case "getRemainingComplicationUserInfoTransferCount":
            checkForWatchSession(result: result)
            if #available(iOS 10.0, *) {
                result(watchSession!.remainingComplicationUserInfoTransfers)
            } else {
                result(0)
            }
            
        case "transferFileInfo":
            checkForWatchSession(result: result)
            if let arguments = call.arguments as? [String: Any],
               let path = arguments["filePath"] as? String,
               let metadata = arguments["metadata"] as? [String: Any] {
                let url = URL.init(fileURLWithPath: path)
                let transfer = watchSession!.transferFile(url, metadata: metadata)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
                    result(transfer.toRawTransferDict())
                })
                self.callbackChannel.invokeMethod("onPendingFileTransferListChanged", arguments: self.watchSession?.outstandingFileTransfers.map{ $0.toRawTransferDict() })
                return
            }
            result(nil)
            
        case "setFileTransferProgressListener":
            checkForWatchSession(result: result)
            if let transferId = call.arguments as? String {
                if let timer = fileProgressTimers[transferId] {
                    timer.invalidate()
                    fileProgressTimers.removeValue(forKey: transferId)
                }
                if let transfer = watchSession!.outstandingFileTransfers.first(where: { transfer in
                    transfer.file.metadata != nil && transfer.file.metadata!.contains{ key, value in
                        key == "id" && value is String && (value as! String) == transferId
                    }
                }) {
                    if #available(iOS 10.0, *) {
                        fileProgressTimers[transferId] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                            if #available(iOS 12.0, *) {
                                if transfer.progress.isCancelled || transfer.progress.isFinished {
                                    timer.invalidate()
                                }
                            } else {
                                timer.invalidate()
                                // Fallback on earlier versions
                            }
                            if #available(iOS 12.0, *) {
                                self.callbackChannel.invokeMethod("onFileProgressChanged", arguments: ["transferId": transferId, "progress": transfer.progress.toProgressDict()])
                            }
                            print(self.fileProgressTimers)
                        }
                    }
                    
                } else {
                    print("No transfer found, please try again")
                    handleFlutterError(result: result, message: "No transfer found, please try again")
                }
                
            } else {
                print("No transfer id specified, please try again")
                handleFlutterError(result: result, message: "No transfer id specified, please try again")
            }
            result(nil)
            
        case "getOnProgressFileTransfers":
            checkForWatchSession(result: result)
            result(watchSession!.outstandingFileTransfers.map{ $0.toRawTransferDict() })
            
        case "cancelUserInfoTransfer":
            checkForWatchSession(result: result)
            if let transferId = call.arguments as? String {
                if let transfer = watchSession!.outstandingUserInfoTransfers.first(where: { transfer in
                    transfer.userInfo.contains{ key, value in
                        key == "id" && value is String && (value as! String) == transferId
                    }
                }) {
                    transfer.cancel()
                    self.callbackChannel.invokeMethod("onPendingUserInfoTransferListChanged", arguments: self.watchSession!.outstandingUserInfoTransfers.map{ $0.toRawTransferDict() })
                } else {
                    print("No transfer found, please try again")
                    handleFlutterError(result: result, message: "No transfer found, please try again")
                }
            } else {
                print("No transfer id specified, please try again")
                handleFlutterError(result: result, message: "No transfer id specified, please try again")
            }
            result(nil)
            
        case "cancelFileTransfer":
            checkForWatchSession(result: result)
            if let transferId = call.arguments as? String {
                if let timer = fileProgressTimers[transferId] {
                    timer.invalidate()
                    fileProgressTimers.removeValue(forKey: transferId)
                }
                if let transfer = watchSession!.outstandingFileTransfers.first(where: { transfer in
                    transfer.file.metadata != nil && transfer.file.metadata!.contains{ key, value in
                        key == "id" && value is String && (value as! String) == transferId
                    }
                }) {
                    transfer.cancel()
                    self.callbackChannel.invokeMethod("onPendingFileTransferListChanged", arguments: self.watchSession!.outstandingFileTransfers.map{ $0.toRawTransferDict() })
                } else {
                    print("No transfer found, please try again")
                    handleFlutterError(result: result, message: "No transfer found, please try again")
                }
            } else {
                print("No transfer id specified, please try again")
                handleFlutterError(result: result, message: "No transfer id specified, please try again")
            }
            result(nil)
        
        case "startWatchApp":
            checkForWatchSession(result: result)
            let activityType = call.arguments as? Int ?? 52
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = HKWorkoutActivityType(rawValue: UInt(activityType)) ?? .walking
            HKHealthStore().startWatchApp(with: configuration) { success, error in
                if success {
                    result(nil)
                } else if let error = error {
                    print("Error starting watch app \(error.localizedDescription)")
                    self.handleFlutterError(result: result, message:  "Error starting watch app")
                } else {
                    print("Unable to start watch app")
                    self.handleFlutterError(result: result, message:  "Unable to start watch app")
                }
            }
            result(nil)
            
        default:
            result(nil)
        }
    }
    
    private func checkForWatchSession(result: FlutterResult) {
        guard watchSession != nil else {
            handleFlutterError(result: result, message: "Session not found, you need to call activate() first to configure a session")
            return
        }
    }
    
    private func checkSessionReachability(result: FlutterResult) {
        if !watchSession!.isReachable {
            handleFlutterError(result: result, message: "Session is not reachable, your companion app is either disconnected or is in offline mode")
            return
        }
    }
}

//MARK: - WCSessionDelegate methods handle
extension SwiftFlutterWatchOsConnectivityPlugin: WCSessionDelegate {
    public func sessionReachabilityDidChange(_ session: WCSession) {
        callbackChannel.invokeMethodOnMainThread("reachabilityChanged", arguments: session.isReachable)
    }
    
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard error == nil else {
            print("Error handling activation complete: \(error!.localizedDescription)")
            handleCallbackError(message: error!.localizedDescription)
            return
        }
        callbackChannel.invokeMethodOnMainThread("reachabilityChanged", arguments: session.isReachable)
        callbackChannel.invokeMethodOnMainThread("activateStateChanged", arguments: activationState.rawValue)
        getPairedDeviceInfo(session: session)
    }
    
    public func sessionDidBecomeInactive(_ session: WCSession) {
        callbackChannel.invokeMethodOnMainThread("activateStateChanged", arguments: session.activationState)
        getPairedDeviceInfo(session: session)
    }
    
    public func sessionDidDeactivate(_ session: WCSession) {
        callbackChannel.invokeMethodOnMainThread("activateStateChanged", arguments: session.activationState)
        getPairedDeviceInfo(session: session)
    }
    
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        var messageContent: [String: Any] = [:]
        messageContent["message"] = message
        callbackChannel.invokeMethodOnMainThread("messageReceived", arguments: messageContent)
    }
    
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        Task { @MainActor in
            var messageContent: [String: Any] = [:]
            let replyHandlerId = ProcessInfo().globallyUniqueString
            messageContent["message"] = message
            messageContent["replyHandlerId"] = replyHandlerId
            callbackChannel.invokeMethod("messageReceived", arguments: messageContent)
            messageReplyHandlers[replyHandlerId] = replyHandler
        }
    }
    
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        callbackChannel.invokeMethodOnMainThread("onApplicationContextUpdated", arguments: getApplicationContext(session: session))
    }
    
    public func sessionWatchStateDidChange(_ session: WCSession) {
        do {
            callbackChannel.invokeMethodOnMainThread("pairDeviceInfoChanged", arguments: try session.toPairedDeviceJsonString())
        } catch {
            print("Error registering session watch state change")
            handleCallbackError(message: error.localizedDescription)
        }
    }
    
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        callbackChannel.invokeMethodOnMainThread("onUserInfoReceived", arguments: userInfo)
    }
    
    public func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if error != nil {
            print("Error transfering userInto: \(error!.localizedDescription)")
            handleCallbackError(message: error!.localizedDescription)
            return
        }
        Task { @MainActor in
            callbackChannel.invokeMethod("onUserInfoTransferDidFinish", arguments: userInfoTransfer.toRawTransferDict())
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.callbackChannel.invokeMethod("onPendingUserInfoTransferListChanged", arguments: self.watchSession!.outstandingUserInfoTransfers.map{ $0.toRawTransferDict() })
        }
    }
    
    public func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error != nil {
            print("Error transfering file: \(error!.localizedDescription)")
            handleCallbackError(message: error!.localizedDescription)
            return
        }
        callbackChannel.invokeMethodOnMainThread("onFileTransferDidFinish", arguments: fileTransfer.toRawTransferDict())
        if let metadata = fileTransfer.file.metadata, let transferId = metadata["id"] as? String, let timer = fileProgressTimers[transferId] {
            timer.invalidate()
            fileProgressTimers.removeValue(forKey: transferId)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.callbackChannel.invokeMethod("onPendingFileTransferListChanged", arguments: self.watchSession!.outstandingFileTransfers.map{ $0.toRawTransferDict() })
        }
    }
    
    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        var tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        tempURL.appendPathComponent(file.fileURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(atPath: tempURL.path)
            }
            try FileManager.default.moveItem(atPath: file.fileURL.path, toPath: tempURL.path)
            var fileDict: [String: Any] = ["path": tempURL.path]
            if let metadata = file.metadata {
                var m = metadata
                for (key, value) in m {
                    if let date = value as? Date {
                        m[key] = Int(date.timeIntervalSince1970)
                    }
                }
                fileDict["metadata"] = m
            }
            
            callbackChannel.invokeMethodOnMainThread("onFileReceived", arguments: fileDict)
        } catch {
            print("Error loading file: \(error.localizedDescription)")
            handleCallbackError(message: error.localizedDescription)
        }
        
    }
}



//MARK: - Helper methods
extension SwiftFlutterWatchOsConnectivityPlugin {
    private func getPairedDeviceInfo(session: WCSession) {
        do {
            callbackChannel.invokeMethodOnMainThread("pairDeviceInfoChanged", arguments: try session.toPairedDeviceJsonString())
        } catch {
            print("Error sending pairDeviceInfo: \(error.localizedDescription)")
            handleCallbackError(message: error.localizedDescription)
        }
    }
    
    private func getApplicationContext(session: WCSession)-> [String: [String: Any]] {
        var applicationContextDict: [String: [String: Any]] = [:]
        applicationContextDict["current"] = session.applicationContext
        applicationContextDict["received"] = session.receivedApplicationContext
        return applicationContextDict
    }
    
    private func handleFlutterError(result: FlutterResult,message: String) {
        result(FlutterError(code: "500", message: message, details: nil))
    }
    
    private func handleCallbackError(message: String) {
        callbackChannel.invokeMethodOnMainThread("onError", arguments: message)
    }
}

extension WCSessionUserInfoTransfer {
    func toRawTransferDict() -> [String: Any] {
        return [
            "isCurrentComplicationInfo": self.isCurrentComplicationInfo,
            "userInfo": self.userInfo,
            "isTransferring": self.isTransferring,
        ]
    }
}

extension WCSessionFileTransfer {
    func toRawTransferDict() -> [String: Any] {
        return [
            "filePath": self.file.fileURL.path,
            "isTransferring": self.isTransferring,
            "metadata": self.file.metadata as Any
        ]
    }
}

extension WCSession {
    func toPairedDeviceJsonString() throws -> String {
        var dict: [String: Any] = [:]
        dict["isPaired"] = self.isPaired
        dict["isComplicationEnabled"] = self.isComplicationEnabled
        dict["isWatchAppInstalled"] = self.isWatchAppInstalled
        if let watchDirectoryUrl = self.watchDirectoryURL {
            dict["watchDirectoryURL"] = watchDirectoryUrl.absoluteString
        }
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        
        return String(data: jsonData, encoding: .utf8) ?? ""
    }
}

extension Progress {
    func toProgressDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["currentProgress"] = self.completedUnitCount
        return dict
    }
}

extension FlutterMethodChannel {
    func invokeMethodOnMainThread(_ method: String, arguments: Any?) {
        DispatchQueue.main.async {
            self.invokeMethod(method, arguments: arguments)
        }
    }
}
