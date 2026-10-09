import AVFoundation

/// One camera session supplies matched color/depth, including color frames when depth is dropped.
final class LidarCapture: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    private let video: AVCaptureVideoDataOutput
    private let depth: AVCaptureDepthDataOutput
    private let synchronizer: AVCaptureDataOutputSynchronizer
    private let process: (CMSampleBuffer, AVDepthData?) -> Void

    init(video: AVCaptureVideoDataOutput, depth: AVCaptureDepthDataOutput,
         process: @escaping (CMSampleBuffer, AVDepthData?) -> Void) {
        self.video = video
        self.depth = depth
        self.process = process
        synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [video, depth])
        super.init()
        synchronizer.setDelegate(self, queue: DispatchQueue(label: "com.clearahead.lidar", qos: .userInitiated))
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let color = collection.synchronizedData(for: video) as? AVCaptureSynchronizedSampleBufferData,
              !color.sampleBufferWasDropped else { return }
        let measurement = collection.synchronizedData(for: depth) as? AVCaptureSynchronizedDepthData
        process(color.sampleBuffer, measurement?.depthDataWasDropped == false ? measurement?.depthData : nil)
    }
}
