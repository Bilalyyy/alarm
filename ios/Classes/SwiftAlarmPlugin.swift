import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import MediaPlayer
import BackgroundTasks

public class SwiftAlarmPlugin: NSObject, FlutterPlugin {

    //MARK: - static properties
    static let sharedInstance = SwiftAlarmPlugin()
    static let backgroundTaskIdentifier: String = "com.gdelataillade.fetch"

    //MARK: - Private properties

#if targetEnvironment(simulator)
    private let isDevice = false
#else
    private let isDevice = true
#endif

    private var registrar: FlutterPluginRegistrar!

    // Dictionnaires pour gérer les lecteurs audio, les tâches, les minuteries et les temps de déclenchement
    private var audioPlayers: [Int: AVAudioPlayer] = [:]
    private var silentAudioPlayer: AVAudioPlayer?
    private var tasksQueue: [Int: DispatchWorkItem] = [:]
    private var timers: [Int: Timer] = [:]
    private var triggerTimes: [Int: Date] = [:]

    // Variables pour les paramètres de notification lors de la fermeture de l'application
    private var notificationTitleOnKill: String!
    private var notificationBodyOnKill: String!

    // Variables pour suivre l'état de l'application
    private var vibrate = false
    private var playSilent = false
    private var previousVolume: Float? = nil

    //MARK: - Public unction

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

    //MARK: - Private function

    // Méthode pour configurer et programmer une alarme
    private func setAlarm(call: FlutterMethodCall, result: FlutterResult) {
        self.mixOtherAudios()

        guard let alarmSettings = call.arguments as? [String: Any], alarmSettings = Args(data: alarmSettings) else {
            result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Arguments are not in the expected format", details: nil))
            return
        }

        scheduleLocalNotification(alarmSettings)
        addObserver(alarmSettings.notifOnKillEnabled)

        guard let audioPlayer = createAudioPlayer(for: alarmSettings) else {
            result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Error creating audio player for ID: \(alarmSettings.id)", details: nil))
            return
        }

        let alarmDate = Date().addingTimeInterval(alarmSettings.delayInSeconds)

        setupPlayer(alarmSettings, at: alarmDate)
        startSilentSound()

        let currentTime = audioPlayer.deviceCurrentTime
        let alarmTime = currentTime + alarmSettings.delayInSeconds + 0.5

        audioPlayer.play(atTime: alarmTime)

        tasksQueue[alarmSettings.id] = createAlarmTask(for: alarmSettings,
                                                            at: alarmDate)

        alarmPlay()

        DispatchQueue.main.async {
            self.saveTimer(id: alarmSettings.id, alarmSettings.delayInSeconds)
            SwiftAlarmPlugin.scheduleAppRefresh()
        }

        result(true)
    }

    private func setupPlayer(_ alarmSettings: Args, at alarmDate: Date) {

        // Enregistre le moment où l'alarme doit se déclencher
        triggerTimes[alarmSettings.id] = alarmDate

        if alarmSettings.loopAudio {
            audioPlayer.numberOfLoops = -1
        }

        audioPlayer.prepareToPlay()

        // Réduit le volume du son de l'alarme si une durée de fondu est spécifiée
        if alarmSettings.fadeDuration > 0.0 {
            audioPlayer.volume = 0.01
        }
    }

    private func alarmPlay() {
        let currentTime = audioPlayer.deviceCurrentTime
        let alarmTime = currentTime + alarmSettings.delayInSeconds + 0.5

        audioPlayer.play(atTime: alarmTime)
    }

    private func saveTimer(id: Int, _ delayInSeconds: Double) {
        timers[id] = Timer.scheduledTimer(timeInterval: delayInSeconds,
                                          target: self,
                                          selector: #selector(executeTask(_:)),
                                          userInfo: id,
                                          repeats: false)

    }


    private func scheduleLocalNotification(_ alarmSettings: Args) {
        NotificationManager.shared.scheduleNotification(id: alarmSettings.id,
                                                        delayInSeconds: alarmSettings.delayInSeconds,
                                                        title: alarmSettings.notificationTitle,
                                                        body: alarmSettings.notificationBody)

        notificationTitleOnKill = alarmSettings.notificationTitleOnKill
        notificationBodyOnKill = alarmSettings.notificationBodyOnKill
    }

    
    private func addObserver(_ notifOnKillEnabled: Bool) {
        guard notifOnKillEnabled else { return }
        NotificationManager.shared.registerForAppTerminationNotification(observer: self,
                                                                         selector: #selector(applicationWillTerminate(_:)))
    }

    private func createAudioPlayer(for alarmSettings: AlarmSettings) -> AVAudioPlayer? {
        // Vérifie si le son de l'alarme est un fichier local ou un fichier dans le bundle de l'application
        let audioPath: String
        if alarmSettings.assetAudio.hasPrefix("assets/") {
            let filename = registrar.lookupKey(forAsset: alarmSettings.assetAudio)
            guard let path = Bundle.main.path(forResource: filename, ofType: nil) else {
                return nil
            }
            audioPath = path
        } else {
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let filename = String(alarmSettings.assetAudio.split(separator: "/").last ?? "")
            audioPath = documentsDirectory.appendingPathComponent(filename).path
        }

        // Crée un lecteur audio à partir du chemin du fichier
        do {
            let audioUrl = URL(fileURLWithPath: audioPath)
            let audioPlayer = try AVAudioPlayer(contentsOf: audioUrl)
            // sauvegarde le player
            audioPlayers[alarmSettings.id] = audioPlayer
            return audioPlayer
        } catch {
            return nil
        }
    }

    private func createAlarmTask(for alarmSettings: Args,at alarmDate: Date) -> DispatchWorkItem {
        // Crée un bloc de code à exécuter après le délai
        return DispatchWorkItem(block: {
            self.handleAlarmAfterDelay(
                id: alarmSettings.id,
                triggerTime: alarmDate,
                fadeDuration: alarmSettings.fadeDuration,
                vibrationsEnabled: alarmSettings.vibrationsEnabled,
                audioLoop: alarmSettings.loopAudio,
                volume: alarmSettings.volume
            )
        })
    }

    // Méthode pour démarrer la lecture d'un son silencieux
    private func startSilentSound(_ playSilent: Bool) {
        guard !playSilent else { return }
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
        if audioPlayers.isEmpty {
            NotificationManager.shared.removeAppTerminationNotificationObserver(observer: self)
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

    // MARK: - Static function

    // Méthode statique pour enregistrer le plugin Flutter
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.gdelataillade/alarm", binaryMessenger: registrar.messenger())
        let instance = SwiftAlarmPlugin()

        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
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

    //MARK: - @objc function

    // Méthode de traitement lors de l'exécution d'une tâche planifiée
    @objc func executeTask(_ timer: Timer) {
        if let taskId = timer.userInfo as? Int, let task = tasksQueue[taskId] {
            task.perform()
        }
    }

    // Méthode pour gérer les notifications à la fermeture de l'application
    @objc func applicationWillTerminate(_ notification: Notification) {
        NotificationManager.shared.notificationOnAppKill(notificationTitleOnKill,
                                                  notificationBodyOnKill)
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

}
