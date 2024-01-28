import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import MediaPlayer
import BackgroundTasks

public class SwiftAlarmPlugin: NSObject, FlutterPlugin {
#if targetEnvironment(simulator)
    private let isDevice = false
#else
    private let isDevice = true
#endif

    private var registrar: FlutterPluginRegistrar!
    static let sharedInstance = SwiftAlarmPlugin()
    static let backgroundTaskIdentifier: String = "com.gdelataillade.fetch"

    // Méthode statique pour enregistrer le plugin Flutter
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.gdelataillade/alarm", binaryMessenger: registrar.messenger())
        let instance = SwiftAlarmPlugin()

        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // Dictionnaires pour gérer les lecteurs audio, les tâches, les minuteries et les temps de déclenchement
    private var audioPlayers: [Int: AVAudioPlayer] = [:]
    private var silentAudioPlayer: AVAudioPlayer?
    private var tasksQueue: [Int: DispatchWorkItem] = [:]
    private var timers: [Int: Timer] = [:]
    private var triggerTimes: [Int: Date] = [:]

    // Variables pour les paramètres de notification lors de la fermeture de l'application
    private var notifOnKillEnabled: Bool!
    private var notificationTitleOnKill: String!
    private var notificationBodyOnKill: String!

    // Variables pour suivre l'état de l'application
    private var observerAdded = false
    private var vibrate = false
    private var playSilent = false
    private var previousVolume: Float? = nil

    // Méthode de traitement des appels de méthodes Flutter
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .default).async {
            if call.method == "setAlarm" {
                self.setAlarm(call: call, result: result)
            } else if call.method == "stopAlarm" {
                if let args = call.arguments as? [String: Any], let id = args["id"] as? Int {
                    self.stopAlarm(id: id, cancelNotif: true, result: result)
                } else {
                    result(FlutterError.init(code: "NATIVE_ERR", message: "[Alarm] Error: id parameter is missing or invalid", details: nil))
                }
            } else if call.method == "audioCurrentTime" {
                let args = call.arguments as! Dictionary<String, Any>
                let id = args["id"] as! Int
                self.audioCurrentTime(id: id, result: result)
            } else {
                DispatchQueue.main.sync {
                    result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    // Méthode pour configurer et programmer une alarme
    private func setAlarm(call: FlutterMethodCall, result: FlutterResult) {
        self.mixOtherAudios()

        guard let args = call.arguments as? [String: Any], args = Args(data: args) else {
            result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Arguments are not in the expected format", details: nil))
            return
        }

        if let notificationTitle = args.notificationTitle && let notificationBody = args.notificationBody && args.delayInSeconds >= 1.0 {
            NotificationManager.shared.scheduleNotification(id: args.id,
                                                            delayInSeconds: args.delayInSeconds,
                                                            title: notificationTitle,
                                                            body: notificationBody)
        }

        notifOnKillEnabled = args.notifOnKillEnabled
        notificationTitleOnKill = args.notificationTitleOnKill
        notificationBodyOnKill = args.notificationBodyOnKill

        if notifOnKillEnabled && !observerAdded {
            observerAdded = true
            NotificationManager.shared.registerForAppTerminationNotification(observer: self, selector: #selector(applicationWillTerminate(_:)))
        }

        if args.assetAudio.hasPrefix("assets/") {
            let filename = registrar.lookupKey(forAsset: args.assetAudio)

            guard let audioPath = Bundle.main.path(forResource: filename, ofType: nil) else {
                result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Audio file not found: \(args.assetAudio)", details: nil))
                return
            }

            do {
                let audioUrl = URL(fileURLWithPath: audioPath)
                let audioPlayer = try AVAudioPlayer(contentsOf: audioUrl)
                self.audioPlayers[args.id] = audioPlayer
            } catch {
                result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Error loading audio player: \(error.localizedDescription)", details: nil))
                return
            }
        } else {
            do {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let filename = String(args.assetAudio.split(separator: "/").last ?? "")
                let assetAudioURL = documentsDirectory.appendingPathComponent(filename)

                let audioPlayer = try AVAudioPlayer(contentsOf: assetAudioURL)
                self.audioPlayers[args.id] = audioPlayer
            } catch {
                result(FlutterError.init(code: "NATIVE_ERR", message: "[Alarm] Error loading given local asset path: \(args.assetAudio)", details: nil))
                return
            }
        }

        guard let audioPlayer = self.audioPlayers[args.id] else {
            result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Audio player not found for ID: \(args.id)", details: nil))
            return
        }

        let currentTime = audioPlayer.deviceCurrentTime
        let time = currentTime + args.delayInSeconds

        let dateTime = Date().addingTimeInterval(args.delayInSeconds)
        self.triggerTimes[args.id] = dateTime

        if args.loopAudio {
            audioPlayer.numberOfLoops = -1
        }

        audioPlayer.prepareToPlay()

        if args.fadeDuration > 0.0 {
            audioPlayer.volume = 0.01
        }

        if !playSilent {
            self.startSilentSound()
        }

        audioPlayer.play(atTime: time + 0.5)

        self.tasksQueue[args.id] = DispatchWorkItem(block: {
            self.handleAlarmAfterDelay(
                id: args.id,
                triggerTime: dateTime,
                fadeDuration: args.fadeDuration,
                vibrationsEnabled: args.vibrationsEnabled,
                audioLoop: args.loopAudio,
                volume: args.volume
            )
        })

        DispatchQueue.main.async {
            self.timers[args.id] = Timer.scheduledTimer(timeInterval: args.delayInSeconds,
                                                        target: self,
                                                        selector: #selector(self.executeTask(_:)),
                                                        userInfo: args.id,
                                                        repeats: false)
            SwiftAlarmPlugin.scheduleAppRefresh()
        }

        result(true)
    }

    // Méthode de traitement lors de l'exécution d'une tâche planifiée
    @objc func executeTask(_ timer: Timer) {
        if let taskId = timer.userInfo as? Int, let task = tasksQueue[taskId] {
            task.perform()
        }
    }

    // Méthode pour démarrer la lecture d'un son silencieux
    private func startSilentSound() {
        let filename = registrar.lookupKey(forAsset: "assets/long_blank.mp3", fromPackage: "alarm")
        if let audioPath = Bundle.main.path(forResource: filename, ofType: nil) {
            let audioUrl = URL(fileURLWithPath: audioPath)
            do {
                self.silentAudioPlayer = try AVAudioPlayer(contentsOf: audioUrl)
                self.silentAudioPlayer?.numberOfLoops = -1
                self.silentAudioPlayer?.volume = 0.1
                self.playSilent = true
                self.silentAudioPlayer?.play()

                NotificationManager.shared.registerForAppTerminationNotification(observer: self,
                                                                                 selector: #selector(handleInterruption))
            } catch {
                NSLog("SwiftAlarmPlugin: Error: Could not create and play audio player: \(error)")
            }
        } else {
            NSLog("SwiftAlarmPlugin: Error: Could not find audio file")
        }
    }

    // Méthode pour gérer les interruptions audio
    @objc func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            self.silentAudioPlayer?.play()
            NSLog("SwiftAlarmPlugin: Interruption began")
        case .ended:
            self.silentAudioPlayer?.play()
            NSLog("SwiftAlarmPlugin: Interruption ended")
        default:
            break
        }
    }

    // Méthode pour répéter la lecture d'un son silencieux
    private func loopSilentSound() {
        self.silentAudioPlayer?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.silentAudioPlayer?.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if self.playSilent {
                    self.loopSilentSound()
                }
            }
        }
    }

    // Méthode pour gérer l'alarme après un délai
    private func handleAlarmAfterDelay(id: Int, triggerTime: Date, 
                                       fadeDuration: Double, vibrationsEnabled: Bool,
                                       audioLoop: Bool, volume: Double?) {
        guard let audioPlayer = self.audioPlayers[id], let storedTriggerTime = triggerTimes[id], triggerTime == storedTriggerTime else {
            return
        }

        self.duckOtherAudios()

        if !audioPlayer.isPlaying || audioPlayer.currentTime == 0.0 {
            self.audioPlayers[id]!.play()
        }

        self.vibrate = vibrationsEnabled
        self.triggerVibrations()

        if !audioLoop {
            let audioDuration = audioPlayer.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + audioDuration) {
                self.stopAlarm(id: id, cancelNotif: false, result: { _ in })
            }
        }

        NSLog("SwiftAlarmPlugin: fadeDuration is \(fadeDuration)s and volume is \(String(describing: volume))");

        self.setVolume(volume: Float(volume), enable: true)

        if fadeDuration > 0.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
                audioPlayer.setVolume(1.0, fadeDuration: fadeDuration)
            }
        }
    }

    // Méthode pour arrêter une alarme
    private func stopAlarm(id: Int, cancelNotif: Bool, result: FlutterResult) {
        if cancelNotif {
            NotificationManager.shared.cancelNotification(id: String(id))
        }

        self.mixOtherAudios()

        self.vibrate = false
        self.setVolume(volume: self.previousVolume, enable: false)

        if let timer = timers[id] {
            timer.invalidate()
            timers.removeValue(forKey: id)
        }

        if let audioPlayer = self.audioPlayers[id] {
            audioPlayer.stop()
            self.audioPlayers.removeValue(forKey: id)
            self.triggerTimes.removeValue(forKey: id)
            self.tasksQueue[id]?.cancel()
            self.tasksQueue.removeValue(forKey: id)
            self.stopSilentSound()
            self.stopNotificationOnKillService()
            result(true)
        } else {
            result(false)
        }
    }

    // Méthode pour arrêter la lecture du son silencieux
    private func stopSilentSound() {
        self.mixOtherAudios()

        if self.audioPlayers.isEmpty {
            self.playSilent = false
            self.silentAudioPlayer?.stop()
            NotificationManager.shared.removeAppTerminationNotificationObserver(observer: self)
            SwiftAlarmPlugin.cancelBackgroundTasks()
        }
    }

    // Méthode pour déclencher des vibrations
    private func triggerVibrations() {
        if vibrate && isDevice {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                AudioServicesDisposeSystemSoundID(kSystemSoundID_Vibrate)
                self.triggerVibrations()
            }
        }
    }

    // Méthode pour définir le volume audio
    public func setVolume(volume: Float?, enable: Bool) {
        guard let volume else { return }
        DispatchQueue.main.async {
            let volumeView = MPVolumeView()

            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
                if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                    self.previousVolume = enable ? slider.value : nil
                    slider.value = volume
                }
                volumeView.removeFromSuperview()
            }
        }
    }

    // Méthode pour obtenir le temps de lecture actuel d'un lecteur audio
    private func audioCurrentTime(id: Int, result: FlutterResult) {
        if let audioPlayer = self.audioPlayers[id] {
            let time = Double(audioPlayer.currentTime)
            result(time)
        } else {
            result(0.0)
        }
    }

    // Méthode pour effectuer des tâches en arrière-plan
    private func backgroundFetch() {
        self.mixOtherAudios()

        self.silentAudioPlayer?.pause()
        self.silentAudioPlayer?.play()

        let ids = Array(self.audioPlayers.keys)

        for id in ids {
            NSLog("SwiftAlarmPlugin: Background check alarm with id \(id)")
            if let audioPlayer = self.audioPlayers[id] {
                let dateTime = self.triggerTimes[id]!
                let currentTime = audioPlayer.deviceCurrentTime
                let time = currentTime + dateTime.timeIntervalSinceNow
                self.audioPlayers[id]!.play(atTime: time)
            }

            let delayInSeconds = self.triggerTimes[id]!.timeIntervalSinceNow
            DispatchQueue.main.async {
                self.timers[id] = Timer.scheduledTimer(timeInterval: delayInSeconds,
                                                       target: self,
                                                       selector: #selector(self.executeTask(_:)),
                                                       userInfo: id,
                                                       repeats: false)
            }
        }
    }

    // Méthode pour arrêter le service de notification à la fermeture de l'application
    private func stopNotificationOnKillService() {
        if audioPlayers.isEmpty && observerAdded {
            NotificationManager.shared.removeAppTerminationNotificationObserver(observer: self)
            observerAdded = false
        }
    }

    // Méthode pour gérer les notifications à la fermeture de l'application
    @objc func applicationWillTerminate(_ notification: Notification) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitleOnKill
        content.body = notificationBodyOnKill
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "notification on app kill", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { (error) in
            if let error = error {
                NSLog("SwiftAlarmPlugin: Failed to show notification on kill service => error: \(error.localizedDescription)")
            } else {
                NSLog("SwiftAlarmPlugin: Trigger notification on app kill")
            }
        }
    }

    // Méthode pour mélanger l'audio avec d'autres sources audio
    private func mixOtherAudios() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("SwiftAlarmPlugin: Error setting up audio session with option mixWithOthers: \(error.localizedDescription)")
        }
    }

    // Méthode pour atténuer le son d'autres sources audio
    private func duckOtherAudios() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("SwiftAlarmPlugin: Error setting up audio session with option duckOthers: \(error.localizedDescription)")
        }
    }

    // Méthode statique pour enregistrer les tâches en arrière-plan
    /// Runs from AppDelegate when the app is launched
    static public func registerBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
                self.scheduleAppRefresh()
                sharedInstance.backgroundFetch()
                task.setTaskCompleted(success: true)
            }
        } else {
            NSLog("SwiftAlarmPlugin: BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }

    // Méthode statique pour planifier un rafraîchissement de l'application
    /// Enables background fetch
    static func scheduleAppRefresh() {
        if #available(iOS 13.0, *) {
            let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)

            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                NSLog("SwiftAlarmPlugin: Could not schedule app refresh: \(error)")
            }
        } else {
            NSLog("SwiftAlarmPlugin: BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }

    // Méthode statique pour annuler les tâches en arrière-plan
    /// Disables background fetch
    static func cancelBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
        } else {
            NSLog("SwiftAlarmPlugin: BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }

}
