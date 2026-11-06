import Foundation
import AVFoundation

actor AudioDropDetector {
    /// One value per actual second, not per decoder buffer (buffer sizes vary).
    static func energyProfile(in url: URL, binSeconds: Double = 1) async throws -> [Double] {
        guard binSeconds.isFinite, (0.01...1).contains(binSeconds) else { throw EssayReleaseError.invalid("Некорректный шаг аудиоанализа.") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EssayReleaseError.invalid("В музыкальном файле нет аудиодорожки.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 1800 else {
            throw EssayReleaseError.invalid("Некорректная длительность музыкального трека.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EssayReleaseError.invalid("Не удалось прочитать музыкальный трек.") }
        var sums = [Double](repeating: 0, count: Int(ceil(duration / binSeconds)))
        var counts = [Int](repeating: 0, count: sums.count)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: byteCount / 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: &samples) == noErr else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard start.isFinite else { continue }
            for (index, sample) in samples.enumerated() {
                let second = Int(floor((start + Double(index) / 8000) / binSeconds))
                guard sums.indices.contains(second) else { continue }
                let value = Double(sample) / 32768
                sums[second] += value * value; counts[second] += 1
            }
        }
        if let error = reader.error { throw error }
        return zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
    }

    static func bestDrop(in energies: [Double]) -> Double {
        let window = min(5, energies.count)
        guard window > 0 else { return 0 }
        let average = (0...(energies.count - window)).map { start in
            energies[start..<(start + window)].reduce(0, +) / Double(window)
        }
        var best = average.indices.max { average[$0] < average[$1] } ?? 0
        if energies.count >= 10 {
            let spikes = (5...(energies.count - 5)).map { start in
                (start, average[start] - energies[(start - 5)..<start].reduce(0, +) / 5)
            }
            if let peak = spikes.max(by: { $0.1 < $1.1 }), peak.1 > 0.05 { best = peak.0 }
        }
        return Double(best)
    }

    static func findDrop(in url: URL) async -> Double {
        guard let energy = try? await energyProfile(in: url) else { return 0 }
        return bestDrop(in: energy)
    }
}
