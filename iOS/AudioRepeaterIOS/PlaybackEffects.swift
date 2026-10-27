import AudioToolbox
import AVFoundation

enum PlaybackEffects {
    static func connect(
        player: AVAudioPlayerNode, engine: AVAudioEngine,
        format: AVAudioFormat, settings: PlaybackSettings
    ) throws {
        try settings.validate()
        var previous: AVAudioNode = player
        func append(_ node: AVAudioNode) {
            engine.attach(node)
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        switch settings.activeEffect {
        case .off:
            break
        case .equalizer:
            let equalizer = AVAudioUnitEQ(numberOfBands: PlaybackSettings.equalizerFrequencies.count)
            for (index, band) in equalizer.bands.enumerated() {
                band.filterType = .parametric
                band.frequency = min(PlaybackSettings.equalizerFrequencies[index], Float(format.sampleRate * 0.45))
                band.bandwidth = 1
                band.gain = settings.equalizerGains[index]
                band.bypass = false
            }
            append(equalizer)
        case .dynamics:
            let dynamics = effect(kAudioUnitSubType_DynamicsProcessor)
            let value = settings.dynamics
            try set(dynamics, kDynamicsProcessorParam_Threshold, value.thresholdDB)
            try set(dynamics, kDynamicsProcessorParam_HeadRoom, value.headroomDB)
            try set(dynamics, kDynamicsProcessorParam_AttackTime, value.attackMS / 1000)
            try set(dynamics, kDynamicsProcessorParam_ReleaseTime, value.releaseMS / 1000)
            try set(dynamics, kDynamicsProcessorParam_MasterGain, value.masterGainDB)
            // Disable expansion so this control changes compression only.
            try set(dynamics, kDynamicsProcessorParam_ExpansionRatio, 1)
            append(dynamics)
            if value.peakLimiter { append(effect(kAudioUnitSubType_PeakLimiter)) }
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
    }

    private static func effect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        ))
    }

    private static func set(_ unit: AVAudioUnit, _ parameter: AudioUnitParameterID, _ value: Float) throws {
        let status = AudioUnitSetParameter(unit.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
        guard status == noErr else { throw PlaybackSettingsError.audioUnit(OSStatusCode: status) }
    }
}
