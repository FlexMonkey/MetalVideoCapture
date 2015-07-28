//
//  ViewController.swift
//  LiveCameraFiltering
//
//  Created by Simon Gladman on 05/07/2015.
//  Copyright © 2015 Simon Gladman. All rights reserved.
//
// Thanks to: http://www.objc.io/issues/21-camera-and-photos/camera-capture-on-ios/
// Thanks to: http://mczonk.de/video-texture-streaming-with-metal/
// Thanks to: http://stackoverflow.com/questions/31147744/converting-cmsamplebuffer-to-cvmetaltexture-in-swift-with-cvmetaltexturecachecre/31242539

import UIKit
import AVFoundation
import CoreMedia
import MetalKit
import MetalPerformanceShaders

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate
{
    let metalView = VideoMetalView(frame: CGRectZero)
    let blurSlider = UISlider(frame: CGRectZero)
    
    var device:MTLDevice!
    
    var videoTextureCache : Unmanaged<CVMetalTextureCacheRef>?
    
    override func viewDidLoad()
    {
        super.viewDidLoad()

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = AVCaptureSessionPresetPhoto
        
        
        let backCamera = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
        
        do
        {
            let input = try AVCaptureDeviceInput(device: backCamera)
            
            captureSession.addInput(input)
        }
        catch
        {
            print("can't access camera")
            return
        }
        
        // although we don't use this, it's required to get captureOutput invoked
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        view.layer.addSublayer(previewLayer)
        
        let videoOutput = AVCaptureVideoDataOutput()

        videoOutput.setSampleBufferDelegate(self, queue: dispatch_queue_create("sample buffer delegate", DISPATCH_QUEUE_SERIAL))
        if captureSession.canAddOutput(videoOutput)
        {
            captureSession.addOutput(videoOutput)
        }
  
        setUpMetal()
        
        view.addSubview(metalView)
        view.addSubview(blurSlider)
        
        blurSlider.addTarget(self, action: "sliderChangeHandler", forControlEvents: UIControlEvents.ValueChanged)
        blurSlider.maximumValue = 50
        
        captureSession.startRunning()
    }
    
    private func setUpMetal()
    {
        guard let device = MTLCreateSystemDefaultDevice() else
        {
            return
        }
        
        self.device = device
        
        metalView.framebufferOnly = false

        // Texture for Y
        
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &videoTextureCache)
        
        // Texture for CbCr
    
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &videoTextureCache)
    }
  
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!)
    {
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)

        // Y: luma
        
        var yTextureRef : Unmanaged<CVMetalTextureRef>?
        
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer!, 0);
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer!, 0);

        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
            videoTextureCache!.takeUnretainedValue(),
            pixelBuffer!,
            nil,
            MTLPixelFormat.R8Unorm,
            yWidth, yHeight, 0,
            &yTextureRef)
        
        // CbCr: CB and CR are the blue-difference and red-difference chroma components /
        
        var cbcrTextureRef : Unmanaged<CVMetalTextureRef>?
        
        let cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer!, 1);
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer!, 1);
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
            videoTextureCache!.takeUnretainedValue(),
            pixelBuffer!,
            nil,
            MTLPixelFormat.RG8Unorm,
            cbcrWidth, cbcrHeight, 1,
            &cbcrTextureRef)
        
        let yTexture = CVMetalTextureGetTexture((yTextureRef?.takeUnretainedValue())!)
        let cbcrTexture = CVMetalTextureGetTexture((cbcrTextureRef?.takeUnretainedValue())!)
        
        self.metalView.addTextures(yTexture: yTexture!, cbcrTexture: cbcrTexture!)
        
        yTextureRef?.release()
        cbcrTextureRef?.release()
    }
    
    func sliderChangeHandler()
    {
        metalView.setBlurSigma(blurSlider.value)
    }
    
    override func viewDidLayoutSubviews()
    {
        metalView.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        
        blurSlider.frame = CGRect(x: 20,
            y: view.frame.height - blurSlider.intrinsicContentSize().height - 20,
            width: view.frame.width - 40,
            height: blurSlider.intrinsicContentSize().height)
    }
    
}

class VideoMetalView: MTKView
{
    var ytexture:MTLTexture?
    var cbcrTexture: MTLTexture?

    var pipelineState: MTLComputePipelineState!
    var defaultLibrary: MTLLibrary!
    var commandQueue: MTLCommandQueue!
    var threadsPerThreadgroup:MTLSize!
    var threadgroupsPerGrid: MTLSize!
    
    var blur: MPSImageGaussianBlur!
    
    required init(frame: CGRect)
    {
        super.init(frame: frame, device:  MTLCreateSystemDefaultDevice())
        
        defaultLibrary = device!.newDefaultLibrary()!
        commandQueue = device!.newCommandQueue()
        
        let kernelFunction = defaultLibrary.newFunctionWithName("YCbCrColorConversion")
        
        do
        {
            pipelineState = try device!.newComputePipelineStateWithFunction(kernelFunction!)
        }
        catch
        {
            fatalError("Unable to create pipeline state")
        }
        
        threadsPerThreadgroup = MTLSizeMake(16, 16, 1)
        threadgroupsPerGrid = MTLSizeMake(2048 / threadsPerThreadgroup.width, 1536 / threadsPerThreadgroup.height, 1)
        
        blur = MPSImageGaussianBlur(device: device!, sigma: 0)
    }

    required init(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }


    func addTextures(yTexture ytexture:MTLTexture, cbcrTexture: MTLTexture)
    {
        self.ytexture = ytexture
        self.cbcrTexture = cbcrTexture
    }

    func setBlurSigma(sigma: Float)
    {
        blur = MPSImageGaussianBlur(device: device!, sigma: sigma)
    }
    
    override func drawRect(dirtyRect: CGRect)
    {
        guard let drawable = currentDrawable, ytexture = ytexture, cbcrTexture = cbcrTexture else
        {
            return
        }
        
        let commandBuffer = commandQueue.commandBuffer()
        let commandEncoder = commandBuffer.computeCommandEncoder()
        
        commandEncoder.setComputePipelineState(pipelineState)

        commandEncoder.setTexture(ytexture, atIndex: 0)
        commandEncoder.setTexture(cbcrTexture, atIndex: 1)
        commandEncoder.setTexture(drawable.texture, atIndex: 2) // out texture
        
        commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        
        commandEncoder.endEncoding()
        
        let inPlaceTexture = UnsafeMutablePointer<MTLTexture?>.alloc(1)
        inPlaceTexture.initialize(drawable.texture)
        
        blur.encodeToCommandBuffer(commandBuffer, inPlaceTexture: inPlaceTexture, fallbackCopyAllocator: nil)
  
        commandBuffer.presentDrawable(drawable)
        
        commandBuffer.commit();
     
        
        
    }
}