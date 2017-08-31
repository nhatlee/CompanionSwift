//
//  MultipeerVideoDataOutput.swift
//  CompanionSwift
//
//  Created by nhatlee on 8/30/17.
//  Copyright © 2017 nhatlee. All rights reserved.
//

import UIKit
import AVFoundation
import CoreFoundation
import MultipeerConnectivity

enum RecordMode{
    case recordModeImpact
    case recordModeNormal
}

protocol MultipeerVideDataOutputDelegate: class{
    func didStartRecording()
    func didStopRecording()
    func lostConnected()
    func didStartSendingVideo()
    func didFinishSendingVideo()
    func raiseFramerate()
    func lowerFramerate()
}

let VIDEO_LENGTH = 6
let VIDEO_WIDTH = 720
let VIDEO_HEIGHT = 1280

class MultipeerVideoDataOutput: AVCaptureVideoDataOutput {
    weak var delegate: MultipeerVideDataOutputDelegate?
    // Multipeer stuff - assistant is optional
    var myDevicePeerId: MCPeerID!
    var session: MCSession!
    var advertiserAssistant: MCAdvertiserAssistant?
    var nearbyAdvertiser: MCNearbyServiceAdvertiser?
    var singleAssetWriter: AVAssetWriter!
    var singleAssetWriterInput: AVAssetWriterInput!
    
    var beforeRecord: Int!
    var afterRecord: Int!
    var beforeRecordTimestamp: UInt64!
    var afterRecordTimestamp: UInt64!
    var lastRecordTimestamp: UInt64!
    
    var videoHeight: Int = 0
    var videoWidth: Int = 0
    var isStopAndSaveVideo: Bool = false
    var count: Int = 0
    var videoOrder: Int = 0
    
    var arrayAssetWriter = [AVAssetWriter]()
    var arrayAssetWriterInput = [AVAssetWriterInput]()
    
    
    var recordMode: RecordMode = .recordModeImpact
    
    lazy var sampleQueue: DispatchQueue = {
         let queue = DispatchQueue(label: "VideoSampleQueue", qos: DispatchQoS.default, attributes:[], autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.inherit, target:nil)
        return queue
    }()
    
    init(with displayName: String) {
        super.init()
        myDevicePeerId = MCPeerID(displayName: displayName)
        session = MCSession(peer: myDevicePeerId, securityIdentity: nil, encryptionPreference: MCEncryptionPreference.none)
        session.delegate = self
        let serviceType = self.normalizeServiceName(UIDevice.current.name)
        /*
         if (useAssistant) {
         _advertiserAssistant = [[MCAdvertiserAssistant alloc] initWithServiceType:serviceType discoveryInfo:nil session:_session];
         [_advertiserAssistant start];
         }
         */
        nearbyAdvertiser = MCNearbyServiceAdvertiser(peer: myDevicePeerId, discoveryInfo: nil, serviceType: serviceType)
        nearbyAdvertiser?.delegate = self
        nearbyAdvertiser?.startAdvertisingPeer()
        
        self.setSampleBufferDelegate(self, queue: sampleQueue)
        self.alwaysDiscardsLateVideoFrames = true
        recordMode = RecordMode.recordModeImpact
        self.startWriter()
    }
    
    func normalizeServiceName(_ inputServiceName: String) -> String{
        let charactersToRemove = CharacterSet.alphanumerics.inverted
        var trimmedString = inputServiceName.components(separatedBy: charactersToRemove).joined(separator: "")
        if trimmedString.count > 15{
            assert(true, "normalizeServiceName too long")
//            trimmedString = trimmedString.substring(to: <#T##String.Index#>)
        }
        return trimmedString
    }
    
    
    func stopRecord() {
        isStopAndSaveVideo = true
        delegate?.didStopRecording()
        if recordMode == RecordMode.recordModeImpact {
            saveVideo(withOrder: videoOrder, completion: {() -> Void in
                self.mergeVideo()
            })
        }
        else {
            saveInSingleMode()
        }
    }
    
    func saveInSingleMode() {
        if singleAssetWriterInput == nil || singleAssetWriter.status == .unknown {
            return
        }
        singleAssetWriterInput.markAsFinished()
        singleAssetWriter.finishWriting(completionHandler: {() -> Void in
            // finish export video
            self.singleAssetWriter = nil
            self.singleAssetWriterInput = nil
            self.sendVideoToPeer()
        })
    }
    
    func mergeVideo() {
        var firstURL: URL? = nil
        var secondURL: URL? = nil
        if videoOrder == 0 {
            firstURL = getRecordedVideoUrl(withOrder: 1)
            secondURL = getRecordedVideoUrl(withOrder: 0)
        }
        else {
            firstURL = getRecordedVideoUrl(withOrder: 0)
            secondURL = getRecordedVideoUrl(withOrder: 1)
        }
        // if only 1 video exists
        if !checkFileExist((firstURL?.path)!) {
            trimVideo(secondURL!)
            return
        }
        let firstAsset = AVAsset(url: firstURL!)
        let secondAsset = AVAsset(url: secondURL!)
        let secondTime: CMTime = secondAsset.duration
        let secondDuration: Double = CMTimeGetSeconds(secondTime)
        let totalDuration: Double = Double(beforeRecord + afterRecord)
        if secondDuration >= totalDuration {
            // only need to trim second video
            trimVideo(secondURL!)
            return
        }
        let mixComposition = AVMutableComposition()
        // 2 - Video track
        let firstTrack: AVMutableCompositionTrack? = mixComposition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try? firstTrack?.insertTimeRange(CMTimeRangeMake(kCMTimeZero, firstAsset.duration), of: firstAsset.tracks(withMediaType: AVMediaType.video)[0], at: kCMTimeZero)
        try? firstTrack?.insertTimeRange(CMTimeRangeMake(kCMTimeZero, secondAsset.duration), of: secondAsset.tracks(withMediaType: AVMediaType.video)[0], at: firstAsset.duration)
        // 4 - Get path
        let resultUrl: URL? = getResultVideoUrl()
        try? FileManager.default.removeItem(at: resultUrl!)
        // 5 - Create exporter
        let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality)
        exporter?.outputURL = resultUrl
        exporter?.outputFileType = AVFileType.mov
        exporter?.shouldOptimizeForNetworkUse = true
        let stopTime: Double = CMTimeGetSeconds(mixComposition.duration)
        let startTime: Double = stopTime - totalDuration
        let start: CMTime = CMTimeMakeWithSeconds(startTime, mixComposition.duration.timescale)
        let end: CMTime = CMTimeMakeWithSeconds(stopTime, mixComposition.duration.timescale)
        let range: CMTimeRange = CMTimeRangeMake(start, CMTimeSubtract(end, start))
        exporter?.timeRange = range
        exporter?.exportAsynchronously(completionHandler: {() -> Void in
            self.sendVideoToPeer()
        })
    }
    
    func trimVideo(_ videoUrl: URL) {
        // 4 - Get result path
        let resultUrl = getResultVideoUrl()
        try? FileManager.default.removeItem(at: resultUrl)
        // 5 - Create exporter
        let videoAsset = AVURLAsset(url: videoUrl, options: nil)
        let exporter = AVAssetExportSession(asset: videoAsset, presetName: AVAssetExportPresetHighestQuality)
        exporter?.outputURL = resultUrl
        exporter?.outputFileType = AVFileType.mov
        exporter?.shouldOptimizeForNetworkUse = true
        let totalDuration = Double(beforeRecord + afterRecord)
        let stopTime = CMTimeGetSeconds((videoAsset.duration))
        let startTime = stopTime - totalDuration
        let start = CMTimeMakeWithSeconds(startTime, Int32(videoAsset.duration.timescale.hashValue))
        let end = CMTimeMakeWithSeconds(stopTime, Int32(videoAsset.duration.timescale.hashValue))
        let range = CMTimeRangeMake(start, CMTimeSubtract(end, start))
        exporter?.timeRange = range
        exporter?.exportAsynchronously(completionHandler: {() -> Void in
            self.sendVideoToPeer()
        })
    }
    
    // MARK: - Recording
    func startRecord(withCommand commandString: String) {
        let strings = commandString.components(separatedBy: " ")
     let timestampString = strings[1]
        let startTimestamp = UInt64(timestampString)
        var currentTimeStamp = UInt64(Date().timeIntervalSince1970 * 10000)
        if strings.count == 4 {
            // impact mode (command contains afterRecord timestamp
            // suppose 2s before and 1s after
            beforeRecord = Int(strings[2])
            afterRecord = Int(strings[3])
            beforeRecordTimestamp = startTimestamp! - UInt64(beforeRecord * 1000)
            afterRecordTimestamp = startTimestamp! + UInt64(afterRecord * 1000)
            while currentTimeStamp < startTimestamp! {
                currentTimeStamp = UInt64(Date().timeIntervalSince1970 * 1000)
                usleep(100)
            }
            prepareToStartRecord()
            // prepare to stop record at stopTimestamp
            currentTimeStamp = UInt64(Date().timeIntervalSince1970 * 1000)
            while currentTimeStamp < afterRecordTimestamp {
                currentTimeStamp = UInt64(Date().timeIntervalSince1970 * 1000)
                usleep(100)
            }
            currentTimeStamp = UInt64(Date().timeIntervalSince1970 * 1000)
            stopRecord()
        }
        else {
            // normal mode
            while currentTimeStamp < startTimestamp! {
                currentTimeStamp = UInt64(Date().timeIntervalSince1970 * 1000)
                usleep(100)
            }
            prepareToStartRecord()
        }
    }
    
    
    func prepareToStartRecord() {
        // init asset writer
        initSingleWriter()
        print("Start recording")
        DispatchQueue.main.async(execute: {() -> Void in
            self.delegate?.didStartRecording()
        })
    }
    
    func getResultVideoUrl() -> URL {
        var documentPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last
        documentPath = documentPath! + "resultVideo.mp4"
        let url = URL(fileURLWithPath: documentPath!)
        return url
    }
    
    func initSingleWriter() {
        singleAssetWriter = try? AVAssetWriter(outputURL: getResultVideoUrl(), fileType: AVFileType.mov)
        let videoSettings: [AnyHashable: Any] = [
            AVVideoCodecKey : AVVideoCodecH264,
            AVVideoWidthKey : Int(videoWidth),
            AVVideoHeightKey : Int(videoHeight)
        ]
        
        singleAssetWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings as? [String : Any] ?? [String : Any]())
        singleAssetWriterInput.expectsMediaDataInRealTime = true
        singleAssetWriter.add(singleAssetWriterInput)
        let url: URL? = getResultVideoUrl()
        try? FileManager.default.removeItem(at: url!)
    }
    
    func checkFileExist(_ path: String) -> Bool {
        if path == "" {
            return false
        }
        var _path = path
        _path = path.removingPercentEncoding!
        let url = URL(fileURLWithPath: _path)
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path)
    }
    
    func sendVideoToPeer() {
        print("Start sending video")
        delegate?.didStartSendingVideo()
        session.sendResource(at: getResultVideoUrl(), withName: "Video", toPeer: session.connectedPeers[0], withCompletionHandler: {(_ error: Error?) -> Void in
            self.delegate?.didFinishSendingVideo()
            // reinit writer
            self.startWriter()
        })
    }
    
    // MARK: - Switch Mode
    func switchMode(withCommand command: String) {
        let strings: [String] = command.components(separatedBy: " ")
        let mode: String = strings[1]
        recordMode = (mode == "impact") ? RecordMode.recordModeImpact : RecordMode.recordModeNormal
    }
    
    
    
    // MARK: - Init Writers
    func initWriters() {
        print("Init writer")
        initWriter(withOrder: 0)
        initWriter(withOrder: 1)
        deleteAllVideo()
    }
    
    func startWriter() {
        initWriters()
        videoOrder = 0
        lastRecordTimestamp = 0
        isStopAndSaveVideo = false
    }
    
    func clearWriter() {
        arrayAssetWriter.removeAll()
        arrayAssetWriterInput.removeAll()
        singleAssetWriter = nil
        singleAssetWriterInput = nil
    }
    
    func saveBuffer(toFile sampleBuffer: CMSampleBuffer?) {
        if recordMode == RecordMode.recordModeImpact && (arrayAssetWriter == nil || arrayAssetWriter.count < 2) {
            return
        }
        if recordMode == RecordMode.recordModeImpact && singleAssetWriter == nil {
            return
        }
        let assetWriter: AVAssetWriter? = arrayAssetWriter[videoOrder]
        let assetWriterInput: AVAssetWriterInput? = arrayAssetWriterInput[videoOrder]
        // write to single writer
        appendBuffer(sampleBuffer, to: singleAssetWriter, input: singleAssetWriterInput)
        // write to multiple writer
        appendBuffer(sampleBuffer, to: assetWriter!, input: assetWriterInput!)
    }
    
    func reset() {
        if isStopAndSaveVideo {
            // if lost connection when saving and sending video
            // then re-init writer
            startWriter()
        }
        isStopAndSaveVideo = false
    }
    
    func appendBuffer(_ sampleBuffer: CMSampleBuffer?, to writer: AVAssetWriter, input: AVAssetWriterInput) {
        if writer == nil || input == nil {
            return
        }
        if CMSampleBufferDataIsReady(sampleBuffer!) {
            if writer.status != .writing && writer.status != .cancelled && writer.status != .failed {
                print("Start writing")
                let startTime: CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer!)
                writer.startWriting()
                writer.startSession(atSourceTime: startTime)
            }
            if input.isReadyForMoreMediaData == true {
                defer {
                }
                do {
                    input.append(sampleBuffer!)
                } catch let e {
                    print("Exception: \(e)")
                }
            }
        }
    }
    
    func saveVideo(withOrder order: Int, completion handler: @escaping () -> ()) {
        if arrayAssetWriter.count == 0 || arrayAssetWriter.count < 2 {
            return
        }
        let assetWriter: AVAssetWriter? = arrayAssetWriter[order]
        let assetWriterInput: AVAssetWriterInput? = arrayAssetWriterInput[order]
        if assetWriter?.status == .unknown {
            return
        }
        assetWriterInput?.markAsFinished()
        assetWriter?.finishWriting(completionHandler: {() -> Void in
            print("End export video \(order)")
//            var err: Error? = nil
            let fm = FileManager()
            try? FileManager.default.removeItem(at: self.getRecordedVideoUrl(withOrder: order))
            try? fm.moveItem(atPath: self.getVideoUrl(withOrder: order).path, toPath: self.getRecordedVideoUrl(withOrder: order).path)
            // reinit asset writer
            self.initWriter(withOrder: order)
            handler()
        })
    }
    
    func getRecordedVideoUrl(withOrder order: Int) -> URL {
        var documentPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last
        documentPath = documentPath! + "recordedvideo\(order).mp4"
        let url = URL(fileURLWithPath: documentPath!)
        return url
    }
    
    func initWriter(withOrder order: Int) {
        try? FileManager.default.removeItem(at: getVideoUrl(withOrder: order))
        let assetWriter = try? AVAssetWriter(outputURL: getVideoUrl(withOrder: order), fileType: AVFileType.mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey : AVVideoCodecH264,
            AVVideoWidthKey : Int(VIDEO_WIDTH),
            AVVideoHeightKey : Int(VIDEO_HEIGHT)
        ]
        
        let assetWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        assetWriterInput.expectsMediaDataInRealTime = true
        assetWriter?.add(assetWriterInput)
        
        arrayAssetWriter.append(assetWriter!)
        arrayAssetWriterInput.append(assetWriterInput)
    }
    
    func getVideoUrl(withOrder order: Int) -> URL {
        var documentPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last
        documentPath = documentPath! + "video\(order).mp4"
        let url = URL(fileURLWithPath: documentPath!)
        return url
    }
    
    func deleteAllVideo() {
        do{
            try? FileManager.default.removeItem(at: getVideoUrl(withOrder: 0))
            try? FileManager.default.removeItem(at: getVideoUrl(withOrder: 1))
            try? FileManager.default.removeItem(at: getRecordedVideoUrl(withOrder: 0))
            try? FileManager.default.removeItem(at: getRecordedVideoUrl(withOrder: 1))
        }catch{
            assert(true, "Cannot delete video")
        }
    }
    
    func setVideoDimension(orientation: UIDeviceOrientation){
        videoWidth = 720
        videoHeight = 1280
    }
}

extension MultipeerVideoDataOutput: MCSessionDelegate{
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        NSLog("%@", "didReceiveData: \(data)")
        guard let commandString = String(data: data, encoding: .utf8) else{
            assert(true, "cannot get command string")
            return
        }
        if commandString == "raiseFramerate"{
            self.delegate?.raiseFramerate()
        }else if commandString == "lowerFramerate"{
            self.delegate?.lowerFramerate()
        }else if commandString.hasPrefix("start"){
            self.startRecord(withCommand: commandString)
        }else if commandString.hasPrefix("stop"){
            self.stopRecord()
            DispatchQueue.main.async {
                self.delegate?.didStopRecording()
            }
        }else if commandString.hasPrefix("switchMode"){
            self.switchMode(withCommand: commandString)
        }else{
            assert(true, "cannot get command status")
        }
    }
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        NSLog("%@", "peer \(peerID) didChangeState: \(state)")
        switch state {
        case .connected:
            print("CONNECTED PEER:\(peerID.displayName)")
        case .connecting:
            print("CONNECTING PEER:\(peerID.displayName)")
        case .notConnected:
            print("PEER NOT CONNECTED:\(peerID.displayName)")
            self.reset()
            self.delegate?.lostConnected()
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        NSLog("%@", "didReceiveStream")
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        NSLog("%@", "didStartReceivingResourceWithName")
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        NSLog("%@", "didFinishReceivingResourceWithName")
    }
}

extension MultipeerVideoDataOutput: AVCaptureVideoDataOutputSampleBufferDelegate{
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection){
        if isStopAndSaveVideo {
            return
        }
        if lastRecordTimestamp == 0 {
            lastRecordTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        }
        saveBuffer(toFile: sampleBuffer)
        if recordMode == RecordMode.recordModeImpact {
            saveAndSwitchVideoOrder()
        }
        // sending buffer
        if session.connectedPeers.count > 0 {
            count += 1
            let divFps: Int = 5
            if count != divFps {
                return
            }
            count = 0
//            CFRetain(sampleBuffer)
            OperationQueue.main.addOperation({() -> Void in
                // start compress and send buffer
                self.send(toPeer: sampleBuffer, from: connection)
            })
        }
    }
    
    func send(toPeer sampleBuffer: CMSampleBuffer, from connections: AVCaptureConnection){
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let inputPort = connections.inputPorts[0]
        let deviceInput = inputPort.input as! AVCaptureDeviceInput
        let frameDuration = deviceInput.device.activeVideoMaxFrameDuration
        
        //scale image
        let cvImage = CMSampleBufferGetImageBuffer(sampleBuffer)
        let ciImage = CIImage(cvPixelBuffer: cvImage!)
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")
        scaleFilter?.setValue(ciImage, forKey: "inputImage")
        scaleFilter?.setValue(0.4, forKey: "inputScale")
        var finalImage = scaleFilter?.value(forKey: "outputImage") as! CIImage
        finalImage = finalImage.transformed(by: CGAffineTransform(rotationAngle: .pi/2))
        let cgBackedImage = cgImageBackedImage(with: finalImage)
        let imageData = UIImageJPEGRepresentation(cgBackedImage, 0.4)
        let dict: [String : Any] = [
            "image": imageData,
            "timestamp" : timestamp,
            "framesPerSecond": frameDuration.timescale
            ]
        let data = NSKeyedArchiver.archivedData(withRootObject: dict)
        do{
        try? session.send(data, toPeers: session.connectedPeers, with: MCSessionSendDataMode.reliable)
        }catch{
            assert(true, "cannot send data to peers")
        }
    }
    
    func cgImageBackedImage(with ciImage: CIImage) -> UIImage {
        let context = CIContext(options: nil)
        let ref: CGImage? = context.createCGImage(ciImage, from: ciImage.extent)
        let image = UIImage(cgImage: ref!, scale: UIScreen.main.scale, orientation: .right)
//        CGImageRelease(ref!)
        return image
    }
    
    func saveAndSwitchVideoOrder() {
        let currentTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        if currentTimestamp - lastRecordTimestamp >= UInt64(VIDEO_LENGTH * 1000) {
            // save video
            saveVideo(withOrder: videoOrder, completion: {
                //
            })
            // switch writer
            videoOrder = 1 - videoOrder
            lastRecordTimestamp = currentTimestamp
        }
    }
}

extension MultipeerVideoDataOutput: MCNearbyServiceAdvertiserDelegate{
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
//        if invitationHandler {
            invitationHandler(true, session)
//        }
    }
}
