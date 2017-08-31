//
//  ViewController.swift
//  CompanionSwift
//
//  Created by nhatlee on 8/30/17.
//  Copyright © 2017 nhatlee. All rights reserved.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    @IBOutlet weak var mcStatusLb: UILabel!
    @IBOutlet weak var ipLb: UILabel!
    @IBOutlet weak var nameLb: UILabel!
    @IBOutlet weak var restartBtn: UIButton!
    @IBOutlet weak var indicator: UIActivityIndicatorView!
    @IBOutlet weak var previewView: PreviewView!
    var netService: NetService?
    var recordAnimationTimer: Timer?
    var timeCount: Int = 0
    
    var captureSession = AVCaptureSession()
    lazy var captureVideoPreviewLayer: AVCaptureVideoPreviewLayer = {
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        previewLayer.backgroundColor = UIColor.green.cgColor
//        previewLayer.frame = previewView.bounds
        return previewLayer
    }()
    
    var multipeerVideoOutput: MultipeerVideoDataOutput = {
        let multipeer = MultipeerVideoDataOutput(with: UIDevice.current.name)
        multipeer.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as String):kCVPixelFormatType_32BGRA]
        return multipeer
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
//        captureSession = AVCaptureSession()
        if let videoDevice = AVCaptureDevice.default(for: AVMediaType.video){
            self.setupCamera(with: videoDevice)
        }else{
            let alert = UIAlertController(title: "Error", message: "No video device", preferredStyle: .alert)
            let action = UIAlertAction(title: "OK", style: .default, handler: nil)
            alert.addAction(action)
            self.present(alert, animated: true, completion: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChange), name: NSNotification.Name.UIDeviceOrientationDidChange, object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
//        appDidBecomeActive()
//        captureVideoPreviewLayer.frame = CGRect(x: 0, y: 0, width: previewView.frame.size.width, height: previewView.frame.size.height)
        captureVideoPreviewLayer.frame = previewView.bounds
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidAppear(animated)
        netService?.stop()
    }
    
    func startServer(){
        netService = NetService(domain: Constaints.kServiceDomain, type: Constaints.kServiceType, name: UIDevice.current.name, port: 8888)
        netService?.delegate = self
        netService?.publish()
        mcStatusLb.text = "Just started"
    }
    
    @objc func orientationChange(){
        
    }
    
    @objc func appDidBecomeActive(){
        self.startServer()
        multipeerVideoOutput.startWriter()
    }
    
    @objc func appDidEnterBackground(){
        multipeerVideoOutput.clearWriter()
    }
    
    func setupCamera(with videoDevice: AVCaptureDevice){
        do{
        let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice)//becarefult with try!
            captureSession.addInput(videoDeviceInput!)
        }catch{
            print("error.localizedDescription")
        }
        configureCameraForHighestFrameRate(device:videoDevice)

        previewView.layer.addSublayer(captureVideoPreviewLayer)
        
        multipeerVideoOutput.delegate = self
        captureSession.addOutput(multipeerVideoOutput)
        
        DispatchQueue.main.async {
            self.captureSession.startRunning()
        }
    }
    
    func configureCameraForHighestFrameRate( device:AVCaptureDevice){
        var bestFormat: AVCaptureDevice.Format? = nil
        var bestFrameRateRange: AVFrameRateRange? = nil
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges{
                if bestFrameRateRange == nil{
                    bestFormat = format
                    bestFrameRateRange = range
                }else if range.maxFrameRate > bestFrameRateRange!.maxFrameRate {
                    bestFormat = format
                    bestFrameRateRange = range
                }
            }
        }
        guard let _bestFormat = bestFormat else{return}
        do{
            try device.lockForConfiguration()
        }catch let error{
            print(error.localizedDescription)
            return
        }
        device.activeFormat = _bestFormat
        device.activeVideoMinFrameDuration = CMTimeMake(1, 120)
        device.activeVideoMaxFrameDuration = CMTimeMake(1, 120)
        device.unlockForConfiguration()
    }

    func startRecordingAnimation() {
        indicator.startAnimating()
        timeCount = 0
        recordAnimationTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(flashAnimation), userInfo: nil, repeats: true)
//        DispatchQueue.main.async(execute: {() -> Void in
//            ipLb.text = "Recording"
//        })
    }
    
    func stopRecordingAnimation() {
        timeCount = 0
        if recordAnimationTimer != nil {
            recordAnimationTimer!.invalidate()
            recordAnimationTimer = nil
        }
        DispatchQueue.main.async(execute: {() -> Void in
            self.restartBtn.setBackgroundImage(UIImage(named: "Restart"), for: .normal)
        })
    }
    
    @objc func flashAnimation(_ timer: Timer) {
        timeCount += 1
        if timeCount % 2 == 0{
            restartBtn.setBackgroundImage(UIImage(named: "Restart-Green"), for: .normal)
            ipLb.isHidden = true
        }
        else {
            restartBtn.setBackgroundImage(UIImage(named: "Restart-Red"), for: .normal)
            ipLb.isHidden = false
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
}

extension ViewController: MultipeerVideDataOutputDelegate{
    func didStartRecording() {
        startRecordingAnimation()
    }
    func didStopRecording() {
        stopRecordingAnimation()
    }
    
    func lostConnected(){
        
    }
    
    func didStartSendingVideo(){
        DispatchQueue.main.async {
            self.indicator.startAnimating()
            self.ipLb.text = "Sending Video"
        }
    }
    
    func didFinishSendingVideo(){
        DispatchQueue.main.async(execute: {() -> Void in
            self.indicator.stopAnimating()
            self.ipLb.text = ""
            self.ipLb.isHidden = true
        })
    }
    
    func raiseFramerate(){
        
    }
    
    func lowerFramerate(){
        
    }
}

extension ViewController: NetServiceDelegate{
    func netServiceDidPublish(_ sender: NetService){
        let deviceOrientation = UIDevice.current.orientation
        multipeerVideoOutput.setVideoDimension(orientation: deviceOrientation)
        self.setOrientation(deviceOrientation)
        nameLb.text = self.netService?.name
        nameLb.isHidden = false
        netService?.resolve(withTimeout: 14.0)
        restartBtn.isEnabled = true
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]){
        
    }
    
    func netServiceDidResolveAddress(_ sender: NetService){
        
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]){
        
    }
    //not delegate
    func setOrientation(_ orientation: UIDeviceOrientation) {
        let connection: AVCaptureConnection? = multipeerVideoOutput.connection(with: AVMediaType.video)
        connection?.videoOrientation = .portrait
    }
}

