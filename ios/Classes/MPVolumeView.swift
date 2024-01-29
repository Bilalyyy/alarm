//
//  MPVolumeView.swift
//  
//
//  Created by Bilal Larose on 29/01/2024.
//

import MediaPlayer

// Extension to update system volume
extension MPVolumeView {
    static func setVolume(_ volume: Float) async throws {
        let volumeView = MPVolumeView()
        let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider

        guard let slider = slider else {
            throw VolumeError.sliderNotFound
        }

        await DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.01) {
            slider.value = volume
        }
    }
}
