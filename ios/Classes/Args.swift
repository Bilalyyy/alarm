//
//  Args.swift
//  
//
//  Created by Bilal Larose on 28/01/2024.
//

struct Args: Codable {
    let id: Int
    let delayInSeconds: Double
    let notifOnKillEnabled: Bool
    let notificationTitleOnKill: String
    let notificationBodyOnKill: String
    let loopAudio: Bool
    let fadeDuration: Double
    let vibrationsEnabled: Bool
    let assetAudio: String

    let notificationTitle: String?
    let notificationBody: String?
    let volume: Double?
}

extension Args {
    init?(data: [String: Any]) {
        guard
            let id = data["id"] as? Int,
            let delayInSeconds = data["delayInSeconds"] as? Double,
            let notifOnKillEnabled = data["notifOnKillEnabled"] as? Bool,
            let notificationTitleOnKill = data["notifTitleOnAppKill"] as? String,
            let notificationBodyOnKill = data["notifDescriptionOnAppKill"] as? String,
            let loopAudio = data["loopAudio"] as? Bool,
            let fadeDuration = data["fadeDuration"] as? Double,
            let vibrationsEnabled = data["vibrate"] as? Bool,
            let assetAudio = data["assetAudio"] as? String
        else {
            return nil
        }

        self.id = id
        self.delayInSeconds = delayInSeconds
        self.notifOnKillEnabled = notifOnKillEnabled
        self.notificationTitleOnKill = notificationTitleOnKill
        self.notificationBodyOnKill = notificationBodyOnKill
        self.loopAudio = loopAudio
        self.fadeDuration = fadeDuration
        self.vibrationsEnabled = vibrationsEnabled
        self.assetAudio = assetAudio

        self.notificationTitle = data["notificationTitle"] as? String
        self.notificationBody = data["notificationBody"] as? String
        self.volume = data["volume"] as? Double

    }
}
