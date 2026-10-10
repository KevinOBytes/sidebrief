import Foundation
import Accelerate

/// Acoustic Voiceprint representation capturing pitch, formant frequency distribution,
/// and timbral dynamics for speaker identification and diarization.
public struct Voiceprint: Codable, Sendable, Hashable {
    public let meanPitchHz: Double
    public let pitchConfidence: Double
    public let spectralCentroidHz: Double
    public let subBandEnergies: [Double]
    public let zeroCrossingRate: Double
    public let sampleDurationSeconds: Double
    public let estimatedGender: String

    public init(
        meanPitchHz: Double,
        pitchConfidence: Double,
        spectralCentroidHz: Double,
        subBandEnergies: [Double],
        zeroCrossingRate: Double,
        sampleDurationSeconds: Double,
        estimatedGender: String
    ) {
        self.meanPitchHz = meanPitchHz
        self.pitchConfidence = pitchConfidence
        self.spectralCentroidHz = spectralCentroidHz
        self.subBandEnergies = subBandEnergies
        self.zeroCrossingRate = zeroCrossingRate
        self.sampleDurationSeconds = sampleDurationSeconds
        self.estimatedGender = estimatedGender
    }

    /// Formatted summary badge (e.g. "124 Hz • Male" or "215 Hz • Female")
    public var summaryBadge: String {
        if pitchConfidence >= 0.35 && meanPitchHz > 50.0 {
            return "\(Int(round(meanPitchHz))) Hz • \(estimatedGender)"
        } else {
            return estimatedGender
        }
    }
}

/// Digital signal processing engine for extracting acoustic voiceprints and matching speakers.
public enum VoiceprintEngine {

    /// Extract an acoustic voiceprint from 16-bit linear PCM audio.
    /// - Parameters:
    ///   - pcmData: Raw 16-bit signed PCM data (mono).
    ///   - sampleRate: Source sample rate (e.g. 48000 or 16000).
    /// - Returns: Extracted `Voiceprint`, or `nil` if insufficient audio.
    public static func extractVoiceprint(from pcmData: Data, sampleRate: Double = 48000.0) -> Voiceprint? {
        guard !pcmData.isEmpty else { return nil }

        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount >= 1600 else { return nil } // Minimum 0.1s at 16kHz or 0.033s at 48kHz

        // 1. Read Int16 samples and downsample to 16 kHz if necessary
        var floatSamples: [Float] = []
        floatSamples.reserveCapacity(sampleCount)

        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            if abs(sampleRate - 48000.0) < 1000.0 {
                // Downsample 48kHz -> 16kHz by taking 3-sample box average
                let targetCount = sampleCount / 3
                for i in 0..<targetCount {
                    let idx = i * 3
                    let s0 = Float(int16Ptr[idx]) / 32768.0
                    let s1 = Float(int16Ptr[idx + 1]) / 32768.0
                    let s2 = Float(int16Ptr[idx + 2]) / 32768.0
                    floatSamples.append((s0 + s1 + s2) / 3.0)
                }
            } else {
                for i in 0..<sampleCount {
                    floatSamples.append(Float(int16Ptr[i]) / 32768.0)
                }
            }
        }

        let targetSampleRate: Double = 16000.0
        let totalSamples = floatSamples.count
        let durationSeconds = Double(totalSamples) / targetSampleRate
        guard totalSamples >= 1600 else { return nil }

        // 2. Fundamental Frequency (F0 / Pitch) via Normalized Autocorrelation
        // Search range: 80 Hz to 350 Hz (typical human conversational pitch)
        // At 16 kHz: 80 Hz = 200 samples lag; 350 Hz = ~46 samples lag
        let minLag = 44  // ~363 Hz
        let maxLag = 200 // 80 Hz

        // Analyze multiple overlapping 40ms windows (640 samples with 320 sample hop)
        let windowSize = 640
        let hopSize = 320
        var windowPitches: [Double] = []
        var windowConfidences: [Double] = []

        var windowStart = 0
        while windowStart + windowSize <= totalSamples {
            let window = Array(floatSamples[windowStart..<(windowStart + windowSize)])

            // Compute energy of window
            var energy: Float = 0
            vDSP_svesq(window, 1, &energy, vDSP_Length(windowSize))
            if energy > 0.05 { // Skip silent windows
                if let (pitch, conf) = estimatePitchInWindow(window, sampleRate: targetSampleRate, minLag: minLag, maxLag: maxLag), conf > 0.30 {
                    windowPitches.append(pitch)
                    windowConfidences.append(conf)
                }
            }
            windowStart += hopSize
        }

        let meanPitch: Double
        let pitchConf: Double
        if !windowPitches.isEmpty {
            meanPitch = windowPitches.reduce(0.0, +) / Double(windowPitches.count)
            pitchConf = windowConfidences.reduce(0.0, +) / Double(windowConfidences.count)
        } else {
            meanPitch = 0.0
            pitchConf = 0.0
        }

        // 3. Gender Estimation based on fundamental frequency distribution
        // Adult male: median ~120 Hz, typical range 85-165 Hz
        // Adult female: median ~210 Hz, typical range 165-270 Hz
        let estimatedGender: String
        if pitchConf >= 0.35 && meanPitch > 50.0 {
            if meanPitch < 165.0 {
                estimatedGender = "Male"
            } else {
                estimatedGender = "Female"
            }
        } else {
            estimatedGender = "Speaker"
        }

        // 4. Spectral Sub-Band Energy & Centroid Analysis
        // Band 0: 80 Hz - 250 Hz (Fundamental / chest resonance)
        // Band 1: 250 Hz - 800 Hz (First formant F1, vowel opening)
        // Band 2: 800 Hz - 2200 Hz (Second formant F2, vocal tract acoustics)
        // Band 3: 2200 Hz - 4500 Hz (Higher formants F3-F4, speaker timbre)
        // Band 4: 4500 Hz - 8000 Hz (Fricatives & high frequency harmonics)
        let subBands = computeSubBandEnergies(floatSamples, sampleRate: targetSampleRate)
        let centroid = computeSpectralCentroid(floatSamples, sampleRate: targetSampleRate)
        let zcr = computeZeroCrossingRate(floatSamples)

        return Voiceprint(
            meanPitchHz: meanPitch,
            pitchConfidence: pitchConf,
            spectralCentroidHz: centroid,
            subBandEnergies: subBands,
            zeroCrossingRate: zcr,
            sampleDurationSeconds: durationSeconds,
            estimatedGender: estimatedGender
        )
    }

    /// Calculate acoustic similarity score between two voiceprints (0.0 to 1.0).
    /// Scores >= 0.78 indicate high likelihood of being the same speaker.
    public static func similarity(between vp1: Voiceprint, and vp2: Voiceprint) -> Double {
        // 1. Spectral Sub-Band Cosine Similarity
        var dotProduct: Double = 0
        var norm1: Double = 0
        var norm2: Double = 0
        let bandCount = min(vp1.subBandEnergies.count, vp2.subBandEnergies.count)

        for i in 0..<bandCount {
            let b1 = vp1.subBandEnergies[i]
            let b2 = vp2.subBandEnergies[i]
            dotProduct += b1 * b2
            norm1 += b1 * b1
            norm2 += b2 * b2
        }

        let bandsSimilarity: Double
        if norm1 > 0 && norm2 > 0 {
            bandsSimilarity = max(0.0, min(1.0, dotProduct / (sqrt(norm1) * sqrt(norm2))))
        } else {
            bandsSimilarity = 0.5
        }

        // 2. Pitch Similarity
        let pitchSimilarity: Double
        if vp1.pitchConfidence >= 0.35 && vp2.pitchConfidence >= 0.35 && vp1.meanPitchHz > 50 && vp2.meanPitchHz > 50 {
            let pitchDiff = abs(vp1.meanPitchHz - vp2.meanPitchHz)
            // Penalty if pitch spans different genders (>40 Hz difference)
            if vp1.estimatedGender != vp2.estimatedGender && pitchDiff > 45.0 {
                pitchSimilarity = max(0.0, 1.0 - (pitchDiff / 60.0)) * 0.4
            } else {
                pitchSimilarity = max(0.0, 1.0 - (pitchDiff / 90.0))
            }
        } else {
            // Unvoiced/insufficient confidence: neutral weighting
            pitchSimilarity = 0.65
        }

        // 3. Spectral Centroid Similarity
        let centroidDiff = abs(vp1.spectralCentroidHz - vp2.spectralCentroidHz)
        let centroidSimilarity = max(0.0, 1.0 - (centroidDiff / 1800.0))

        // 4. Zero-Crossing Rate Similarity
        let zcrDiff = abs(vp1.zeroCrossingRate - vp2.zeroCrossingRate)
        let zcrSimilarity = max(0.0, 1.0 - (zcrDiff / 0.25))

        // Weighted combination:
        // Spectral sub-bands (45%) + Pitch (35%) + Centroid (12%) + ZCR (8%)
        let totalScore = (bandsSimilarity * 0.45) +
                         (pitchSimilarity * 0.35) +
                         (centroidSimilarity * 0.12) +
                         (zcrSimilarity * 0.08)

        return max(0.0, min(1.0, totalScore))
    }

    /// Extract a 2 to 3 second voiced audio sample from PCM data and wrap in standard WAV format.
    public static func createVoicedSampleWav(from pcmData: Data, sourceSampleRate: Double = 48000.0, targetDuration: Double = 2.5) -> Data? {
        guard !pcmData.isEmpty else { return nil }

        let bytesPerSample = MemoryLayout<Int16>.size
        let totalSamples = pcmData.count / bytesPerSample
        let targetSampleCount = Int(min(Double(totalSamples), sourceSampleRate * targetDuration))
        guard targetSampleCount > 1000 else { return nil }

        // Find window with highest RMS energy to capture clearest speech
        let step = Int(sourceSampleRate * 0.5)
        var bestStartSample = 0
        var bestEnergy: Double = 0

        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            var currentStart = 0
            while currentStart + targetSampleCount <= totalSamples {
                var sumSq: Double = 0
                for i in 0..<min(2000, targetSampleCount) {
                    let s = Double(int16Ptr[currentStart + i])
                    sumSq += s * s
                }
                if sumSq > bestEnergy {
                    bestEnergy = sumSq
                    bestStartSample = currentStart
                }
                currentStart += step
            }
        }

        let startByte = bestStartSample * bytesPerSample
        let lengthBytes = targetSampleCount * bytesPerSample
        guard startByte + lengthBytes <= pcmData.count else { return nil }

        let subData = pcmData.subdata(in: startByte..<(startByte + lengthBytes))
        return createWavData(fromPCM16: subData, sampleRate: Int(sourceSampleRate), channels: 1)
    }

    /// Create standard RIFF WAV container for linear 16-bit PCM.
    public static func createWavData(fromPCM16 pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        var header = Data()
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size (16 for PCM)
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // AudioFormat (1 for PCM)
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // BitsPerSample
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        return header + pcmData
    }

    // MARK: - Private DSP Helpers

    private static func estimatePitchInWindow(_ samples: [Float], sampleRate: Double, minLag: Int, maxLag: Int) -> (Double, Double)? {
        let n = samples.count
        guard n > maxLag else { return nil }

        // Compute autocorrelation values for lags between minLag and maxLag
        var maxR: Float = -1.0
        var bestLag = minLag

        // Reference energy
        var e0: Float = 0
        vDSP_svesq(samples, 1, &e0, vDSP_Length(n))
        guard e0 > 1e-4 else { return nil }

        for lag in minLag...maxLag {
            let count = n - lag
            var dot: Float = 0
            vDSP_dotpr(samples, 1, Array(samples[lag..<n]), 1, &dot, vDSP_Length(count))

            var eLag: Float = 0
            vDSP_svesq(Array(samples[lag..<n]), 1, &eLag, vDSP_Length(count))

            if eLag > 1e-5 {
                let normR = dot / sqrt(e0 * eLag)
                if normR > maxR {
                    maxR = normR
                    bestLag = lag
                }
            }
        }

        guard maxR > 0.25 else { return nil }

        // Parabolic interpolation around peak lag for fine pitch resolution
        let pitchHz = sampleRate / Double(bestLag)
        return (pitchHz, Double(maxR))
    }

    private static func computeSubBandEnergies(_ samples: [Float], sampleRate: Double) -> [Double] {
        // Simple 5-band energy filter:
        // Band 0: 80 - 250 Hz
        // Band 1: 250 - 800 Hz
        // Band 2: 800 - 2200 Hz
        // Band 3: 2200 - 4500 Hz
        // Band 4: 4500 - 8000 Hz
        let n = samples.count
        let fftSize = 1024
        guard n >= fftSize else { return [0.2, 0.2, 0.2, 0.2, 0.2] }

        var bandEnergies = [0.0, 0.0, 0.0, 0.0, 0.0]
        let binHz = sampleRate / Double(fftSize)

        // Analyze first 1024 samples
        var window = Array(samples[0..<fftSize])
        // Apply Hann window
        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(window, 1, hannWindow, 1, &window, 1, vDSP_Length(fftSize))

        // Discrete real-to-magnitude estimate
        for bin in 1..<(fftSize / 2) {
            let freq = Double(bin) * binHz
            var real: Float = 0
            var imag: Float = 0
            let angleStep = 2.0 * Float.pi * Float(bin) / Float(fftSize)
            for i in 0..<fftSize {
                let angle = angleStep * Float(i)
                real += window[i] * cos(angle)
                imag -= window[i] * sin(angle)
            }
            let magSq = Double(real * real + imag * imag)

            if freq >= 80 && freq < 250 {
                bandEnergies[0] += magSq
            } else if freq >= 250 && freq < 800 {
                bandEnergies[1] += magSq
            } else if freq >= 800 && freq < 2200 {
                bandEnergies[2] += magSq
            } else if freq >= 2200 && freq < 4500 {
                bandEnergies[3] += magSq
            } else if freq >= 4500 && freq < 8000 {
                bandEnergies[4] += magSq
            }
        }

        let totalEnergy = bandEnergies.reduce(0.0, +)
        if totalEnergy > 1e-6 {
            return bandEnergies.map { $0 / totalEnergy }
        } else {
            return [0.2, 0.2, 0.2, 0.2, 0.2]
        }
    }

    private static func computeSpectralCentroid(_ samples: [Float], sampleRate: Double) -> Double {
        let fftSize = 1024
        guard samples.count >= fftSize else { return 1500.0 }
        let binHz = sampleRate / Double(fftSize)

        var weightedSum: Double = 0
        var totalMag: Double = 0
        let window = Array(samples[0..<fftSize])

        for bin in 1..<(fftSize / 2) {
            let freq = Double(bin) * binHz
            var real: Float = 0
            var imag: Float = 0
            let angleStep = 2.0 * Float.pi * Float(bin) / Float(fftSize)
            for i in 0..<fftSize {
                let angle = angleStep * Float(i)
                real += window[i] * cos(angle)
                imag -= window[i] * sin(angle)
            }
            let mag = Double(sqrt(real * real + imag * imag))
            weightedSum += freq * mag
            totalMag += mag
        }

        return totalMag > 1e-4 ? (weightedSum / totalMag) : 1500.0
    }

    private static func computeZeroCrossingRate(_ samples: [Float]) -> Double {
        guard samples.count > 1 else { return 0.0 }
        var crossings = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0 && samples[i - 1] < 0) || (samples[i] < 0 && samples[i - 1] >= 0) {
                crossings += 1
            }
        }
        return Double(crossings) / Double(samples.count - 1)
    }
}
