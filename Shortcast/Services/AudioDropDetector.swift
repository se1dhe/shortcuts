import Foundation
import AVFoundation

/// Analyzes an audio file to find the "drop" or the most energetic part of the song.
actor AudioDropDetector {
    
    /// Finds the timestamp (in seconds) of the best drop/climax in the track.
    /// It scans the audio file using AVAssetReader and calculates RMS energy windows.
    static func findDrop(in audioURL: URL) async -> Double {
        let asset = AVURLAsset(url: audioURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        guard let duration = try? await asset.load(.duration).seconds, duration > 15 else { return 0 }
        
        do {
            let reader = try AVAssetReader(asset: asset)
            // Downmix to mono, PCM, low sample rate for fast processing
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 8000, // 8kHz is enough for energy detection
                AVNumberOfChannelsKey: 1
            ]
            
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(output)
            reader.startReading()
            
            var energies: [Float] = []
            
            
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = [Int16](repeating: 0, count: length / 2)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
                
                // Process in 1-second chunks (or fraction thereof)
                var currentSum: Float = 0
                for sample in data {
                    let floatSample = Float(sample) / 32768.0
                    currentSum += floatSample * floatSample
                }
                energies.append(currentSum / Float(max(1, data.count)))
            }
            
            // Find the 5-second window with the highest energy
            let windowSeconds = 5
            var maxEnergy: Float = 0
            var bestStartSecond: Int = 0
            
            if energies.count > windowSeconds {
                for i in 0...(energies.count - windowSeconds) {
                    let windowEnergy = energies[i..<(i + windowSeconds)].reduce(0, +)
                    if windowEnergy > maxEnergy {
                        maxEnergy = windowEnergy
                        bestStartSecond = i
                    }
                }
                
                // If the track is very long, prefer drops that are at least 10 seconds in
                // unless the first 10 seconds is genuinely the loudest.
                // A true drop usually has a spike (low energy followed by high energy).
                var bestSpike: Float = 0
                var bestSpikeSecond: Int = 0
                
                for i in 5...(energies.count - windowSeconds) {
                    let prevEnergy = energies[(i - 5)..<i].reduce(0, +) / 5.0
                    let dropEnergy = energies[i..<(i + windowSeconds)].reduce(0, +) / Float(windowSeconds)
                    let spike = dropEnergy - prevEnergy
                    
                    if spike > bestSpike {
                        bestSpike = spike
                        bestSpikeSecond = i
                    }
                }
                
                // If we found a significant spike, use it, otherwise use the loudest part
                if bestSpike > 0.05 {
                    return Double(bestSpikeSecond)
                } else {
                    return Double(bestStartSecond)
                }
            }
            
            return 0
        } catch {
            return 0
        }
    }
}
