import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import MediaPlayer
import BackgroundTasks

public class SwiftAlarmPlugin: NSObject, FlutterPlugin {

    //MARK: - static properties

    /// The shared instance of SwiftAlarmPlugin.
    static let sharedInstance = SwiftAlarmPlugin()
    /// Identifier for background task.
    static let backgroundTaskIdentifier: String = "com.gdelataillade.fetch"

    //MARK: - Private properties

#if targetEnvironment(simulator)
    private let isDevice = false
#else
    private let isDevice = true
#endif

    private var registrar: FlutterPluginRegistrar!

    // Dictionaries to manage audio players, tasks, timers, and trigger times
    private var audioPlayers: [Int: AVAudioPlayer] = [:]
    private var silentAudioPlayer: AVAudioPlayer?
    private var tasksQueue: [Int: DispatchWorkItem] = [:]
    private var timers: [Int: Timer] = [:]
    private var triggerTimes: [Int: Date] = [:]

    // Variables for notification parameters on app termination
    private var notificationTitleOnKill: String = ""
    private var notificationBodyOnKill: String = ""

    // Variables to track application state
    private var vibrate = false
    private var playSilent = false
    private var previousVolume: Float? = nil

    //MARK: - Init

    private init() { }

    //MARK: - Public functions

    /// Method to handle Flutter method calls.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let alarmSettings = fetchSettings(call) else {
            result(FlutterError(code: "NATIVE_ERR", message: "[Alarm] Arguments are not in the expected format", details: nil))
            return
        }

        DispatchQueue.global(qos: .default).async {
            switch call.method {
            case "setAlarm":
                self.setAlarm(alarmSettings, result: result)
                self.setupNotificationCenter(alarmSettings)
            case "stopAlarm":
                self.stopAlarm(alarmSettings.id, cancelNotif: true, result: result)

            case "audioCurrentTime":
                self.audioCurrentTime(alarmSettings.id, result: result)

            default:
                DispatchQueue.main.sync {
                    result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    /// Method to set audio volume.
    public func setVolume(volume: Float?, enable: Bool) async {
        guard let volume else { return }
        do {
            self.previousVolume = enable ? try await MPVolumeView.setVolume(volume) : nil
        } catch {
            NSLog("SwiftAlarmPlugin: The volume cannot be adjusted: \(error)")
        }
    }

    //MARK: - Private function

    /// Method to fetch Args object.
    private func fetchSettings(_ call: FlutterMethodCall) -> Args? {
        guard let alarmSettings = call.arguments as? [String: Any], alarmSettings = Args(data: alarmSettings) else {
            return nil
        }
        return alarmSettings
    }

    /// Method to configure and schedule an alarm.
    private func setAlarm(_ alarmSettings: Args, result: FlutterResult) {
        mixOtherAudios()

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

    /// Method to configure player settings.
    private func setupPlayer(_ alarmSettings: Args, at alarmDate: Date) {
        // Records when the alarm should go off
        triggerTimes[alarmSettings.id] = alarmDate

        if alarmSettings.loopAudio {
            audioPlayer.numberOfLoops = -1
        }

        audioPlayer.prepareToPlay()

        // Reduces the volume of the alarm sound if a fade duration is specified
        if alarmSettings.fadeDuration > 0.0 {
            audioPlayer.volume = 0.01
        }
    }

    /// Method to play alarm sound.
    private func alarmPlay() {
        let currentTime = audioPlayer.deviceCurrentTime
        let alarmTime = currentTime + alarmSettings.delayInSeconds + 0.5

        audioPlayer.play(atTime: alarmTime)
    }

    /// Method to save timer for the alarm.
    private func saveTimer(id: Int, _ delayInSeconds: Double) {
        timers[id] = Timer.scheduledTimer(timeInterval: delayInSeconds,
                                          target: self,
                                          selector: #selector(executeTask(_:)),
                                          userInfo: id,
                                          repeats: false)

    }

    /// Method to schedule local notification for the alarm.
    private func setupNotificationCenter(_ alarmSettings: Args) {
        NotificationManager.shared.scheduleNotification(id: alarmSettings.id,
                                                        delayInSeconds: alarmSettings.delayInSeconds,
                                                        title: alarmSettings.notificationTitle,
                                                        body: alarmSettings.notificationBody)
        saveNotifOnKill()
        addObserver(alarmSettings.notifOnKillEnabled)
    }

    /// Method to save notification on kill settings.
    private func saveNotifOnKill() {
        notificationTitleOnKill = alarmSettings.notificationTitleOnKill
        notificationBodyOnKill = alarmSettings.notificationBodyOnKill
    }

    /// Method to add observer for app termination notification.
    private func addObserver(_ notifOnKillEnabled: Bool) {
        guard notifOnKillEnabled else { return }
        NotificationManager.shared.registerForAppTerminationNotification(observer: self,
                                                                         selector: #selector(applicationWillTerminate(_:)))
    }

    /// Method to create audio player for the alarm sound.
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

    /// Method to create a DispatchWorkItem for the alarm.
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

    // Method to start playing a silent sound
    private func startSilentSound(_ playSilent: Bool) {
        guard !playSilent else {
            NSLog("SwiftAlarmPlugin: silentAudioPlayer is already playing")
            return }
        let filename = registrar.lookupKey(forAsset: "assets/long_blank.mp3", fromPackage: "alarm")
        guard let audioPath = Bundle.main.path(forResource: filename, ofType: nil) else {
            NSLog("SwiftAlarmPlugin: Error: Could not find audio file")
            return }

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
    }

    // Method to repeat playing a silent sound
    private func loopSilentSound() {
        silentAudioPlayer?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.silentAudioPlayer?.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if self.playSilent {
                    self.loopSilentSound()
                }
            }
        }
    }

    // Method to manage the alarm after a delay
    private func handleAlarmAfterDelay(id: Int, triggerTime: Date,
                                       fadeDuration: Double, vibrationsEnabled: Bool,
                                       audioLoop: Bool, volume: Double?) {
        guard let audioPlayer = audioPlayers[id], let storedTriggerTime = triggerTimes[id], triggerTime == storedTriggerTime else {
            return
        }

        duckOtherAudios()

        if !audioPlayer.isPlaying || audioPlayer.currentTime == 0.0 {
            audioPlayers[id]!.play()
        }

        vibrate = vibrationsEnabled
        triggerVibrations()

        if !audioLoop {
            let audioDuration = audioPlayer.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + audioDuration) {
                self.stopAlarm(id, cancelNotif: false, result: { _ in })
            }
        }

        NSLog("SwiftAlarmPlugin: fadeDuration is \(fadeDuration)s and volume is \(String(describing: volume))");

        setVolume(volume: Float(volume), enable: true)

        if fadeDuration > 0.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
                audioPlayer.setVolume(1.0, fadeDuration: fadeDuration)
            }
        }
    }

    // Method to stop an alarm
    private func stopAlarm(_ id: Int, cancelNotif: Bool, result: FlutterResult) {
        if cancelNotif {
            NotificationManager.shared.cancelNotification(id: String(id))
        }

        mixOtherAudios()

        vibrate = false
        setVolume(volume: previousVolume, enable: false)

        if let timer = timers[id] {
            timer.invalidate()
            timers.removeValue(forKey: id)
        }

        guard let audioPlayer = audioPlayers[id] else {
            result(false)
            return }
        audioPlayer.stop()
        audioPlayers.removeValue(forKey: id)
        triggerTimes.removeValue(forKey: id)
        tasksQueue[id]?.cancel()
        tasksQueue.removeValue(forKey: id)
        stopSilentSound()
        stopNotificationOnKillService()
        result(true)
    }

    // Method to Stop Playing Silent Sound
    private func stopSilentSound() {
        mixOtherAudios()

        if audioPlayers.isEmpty {
            playSilent = false
            silentAudioPlayer?.stop()
            NotificationManager.shared.removeAppTerminationNotificationObserver(observer: self)
            SwiftAlarmPlugin.cancelBackgroundTasks()
        }
    }

    // Method for triggering vibrations
    private func triggerVibrations() {
        if vibrate && isDevice {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                AudioServicesDisposeSystemSoundID(kSystemSoundID_Vibrate)
                self.triggerVibrations()
            }
        }
    }

    // Method to get the current playing time of an audio player
    private func audioCurrentTime(_ id: Int, result: FlutterResult) {
        if let audioPlayer = audioPlayers[id] {
            let time = Double(audioPlayer.currentTime)
            result(time)
        } else {
            result(0.0)
        }
    }

    // Method to perform tasks in the background
    private func backgroundFetch() {
        mixOtherAudios()

        silentAudioPlayer?.pause()
        silentAudioPlayer?.play()

        let ids = Array(audioPlayers.keys)

        for id in ids {
            NSLog("SwiftAlarmPlugin: Background check alarm with id \(id)")
            if let audioPlayer = audioPlayers[id] {
                let dateTime = triggerTimes[id]!
                let currentTime = audioPlayer.deviceCurrentTime
                let time = currentTime + dateTime.timeIntervalSinceNow
                audioPlayers[id]!.play(atTime: time)
            }

            let delayInSeconds = triggerTimes[id]!.timeIntervalSinceNow
            DispatchQueue.main.async {
                self.timers[id] = Timer.scheduledTimer(timeInterval: delayInSeconds,
                                                       target: self,
                                                       selector: #selector(self.executeTask(_:)),
                                                       userInfo: id,
                                                       repeats: false)
            }
        }
    }

    // Method to stop notification service when app closes
    private func stopNotificationOnKillService() {
        if audioPlayers.isEmpty {
            NotificationManager.shared.removeAppTerminationNotificationObserver(observer: self)
        }
    }

    // Method for mixing audio with other audio sources
    private func mixOtherAudios() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("SwiftAlarmPlugin: Error setting up audio session with option mixWithOthers: \(error.localizedDescription)")
        }
    }

    // Method to attenuate the sound of other audio sources
    private func duckOtherAudios() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("SwiftAlarmPlugin: Error setting up audio session with option duckOthers: \(error.localizedDescription)")
        }
    }

    // MARK: - Static function

    // Static method to register Flutter plugin
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.gdelataillade/alarm", binaryMessenger: registrar.messenger())
        let instance = SwiftAlarmPlugin()

        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    /// Static method to save background tasks
    /// runs from AppDelegate when the app is launched
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

    /// Static method to schedule an application refresh
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

    /// Static method to cancel background fetch
    static func cancelBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
        } else {
            NSLog("SwiftAlarmPlugin: BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }

    //MARK: - @objc function

    // Processing method when running a scheduled task
    @objc private func executeTask(_ timer: Timer) {
        if let taskId = timer.userInfo as? Int, let task = tasksQueue[taskId] {
            task.perform()
        }
    }

    // Method to manage notifications when closing the application
    @objc private func applicationWillTerminate(_ notification: Notification) {
        NotificationManager.shared.notificationOnAppKill(notificationTitleOnKill,
                                                  notificationBodyOnKill)
    }

    // Method to handle audio interruptions
    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            silentAudioPlayer?.play()
            NSLog("SwiftAlarmPlugin: Interruption began")
        case .ended:
            silentAudioPlayer?.play()
            NSLog("SwiftAlarmPlugin: Interruption ended")
        default:
            break
        }
    }

}
