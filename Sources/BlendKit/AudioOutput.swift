// Blend kit: plays the engine through the default output device.
import AVFoundation
import BlendEngine
import Foundation

public final class AudioOutput {
    private let av = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var observer: NSObjectProtocol?

    public init(engine: Engine) {
        let raw = engine.raw
        guard let format = AVAudioFormat(standardFormatWithSampleRate: engine.sampleRate, channels: 2) else { return }
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            be_render(raw, left, right, Int32(frameCount))
            return noErr
        }
        node = source
        av.attach(source)
        av.connect(source, to: av.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: av, queue: .main) { [weak self] _ in
            try? self?.start()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        av.stop()
    }

    public func start() throws {
        if av.isRunning { return }
        av.prepare()
        try av.start()
    }

    public func stop() { av.stop() }
}
