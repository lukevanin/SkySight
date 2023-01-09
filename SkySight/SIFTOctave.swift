//
//  SIFTOctave.swift
//  SkySight
//
//  Created by Luke Van In on 2023/01/03.
//

import Foundation
import Metal


struct SIFTGradient {
    
    static let zero = SIFTGradient(orientation: 0, magnitude: 0)
    
    let orientation: Float
    let magnitude: Float
}


final class SIFTOctave {
    
    let scale: DifferenceOfGaussians.Octave
    
    let keypointTextures: MTLTexture
    let keypointImages: [Image<Float>]

    let gradientTextures: MTLTexture

    private let device: MTLDevice
    private let extremaFunction: SIFTExtremaFunction
    private let gradientFunction: SIFTGradientKernel
    private let interpolateFunction: SIFTInterpolateKernel
    private let orientationFunction: SIFTOrientationKernel
    private let descriptorFunction: SIFTDescriptorKernel

    init(
        device: MTLDevice,
        scale: DifferenceOfGaussians.Octave,
        extremaFunction: SIFTExtremaFunction,
        gradientFunction: SIFTGradientKernel
    ) {
        self.device = device
        self.scale = scale
        self.extremaFunction = extremaFunction
        self.gradientFunction = gradientFunction

        let keypointTextures = {
            let textureDescriptor: MTLTextureDescriptor = {
                let descriptor = MTLTextureDescriptor()
                descriptor.textureType = .type2DArray
                descriptor.pixelFormat = .r32Float
                descriptor.width = scale.size.width
                descriptor.height = scale.size.height
                descriptor.arrayLength = scale.numberOfScales
                descriptor.mipmapLevelCount = 1
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .shared
                return descriptor
            }()
            let texture = device.makeTexture(descriptor: textureDescriptor)!
            texture.label = "siftKeypointExtremaTexture"
            return texture
        }()
        self.keypointTextures = keypointTextures

        let gradientTextures = {
            let textureDescriptor: MTLTextureDescriptor = {
                let descriptor = MTLTextureDescriptor()
                descriptor.textureType = .type2DArray
                descriptor.pixelFormat = .rg32Float
                descriptor.width = scale.size.width
                descriptor.height = scale.size.height
                descriptor.arrayLength = scale.gaussianTextures.arrayLength
                descriptor.mipmapLevelCount = 1
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .shared
                return descriptor
            }()
            let texture = device.makeTexture(descriptor: textureDescriptor)!
            texture.label = "siftGradientTexture"
            return texture
        }()
        self.gradientTextures = gradientTextures
        
        
        self.interpolateFunction = SIFTInterpolateKernel(
            device: device
        )

        self.orientationFunction = SIFTOrientationKernel(
            device: device
        )

        self.descriptorFunction = SIFTDescriptorKernel(
            device: device
        )

        self.keypointImages = {
            var images = [Image<Float>]()
            for i in 0 ..< keypointTextures.arrayLength {
                let image = Image<Float>(
                    texture: keypointTextures,
                    label: "siftKeypointExtremaBuffer",
                    slice: i,
                    defaultValue: .zero
                )
                images.append(image)
            }
            return images
        }()
    }
    
    func encode(commandBuffer: MTLCommandBuffer) {
        encodeExtrema(commandBuffer: commandBuffer)
        encodeGradients(commandBuffer: commandBuffer)
    }
    
    private func encodeExtrema(commandBuffer: MTLCommandBuffer) {
        extremaFunction.encode(
            commandBuffer: commandBuffer,
            inputTexture: scale.differenceTextures,
            outputTexture: keypointTextures
        )
    }
    
    private func encodeGradients(commandBuffer: MTLCommandBuffer) {
        gradientFunction.encode(
            commandBuffer: commandBuffer,
            inputTexture: scale.gaussianTextures,
            outputTexture: gradientTextures
        )
    }
    
    func updateImagesFromTextures() {
        for image in keypointImages {
            image.updateFromTexture()
        }
    }

    func getKeypoints() -> [SIFTKeypoint] {
        return getKeypointsFromImages()
    }

    private func getKeypointsFromImages() -> [SIFTKeypoint] {
        var keypoints = [SIFTKeypoint]()
        for s in 0 ..< keypointImages.count {
            for y in 0 ..< scale.size.height {
                for x in 0 ..< scale.size.width  {
                    if let keypoint = keypointAt(x: x, y: y, s: s) {
                        keypoints.append(keypoint)
                    }
                }
            }
        }
        return keypoints
    }
    
    private func keypointAt(x: Int, y: Int, s: Int) -> SIFTKeypoint? {
        let image = keypointImages[s]
        let output = image[x, y]
        let extrema = output == 1

        if extrema == false {
            return nil
        }

        let keypoint = SIFTKeypoint(
            octave: scale.o,
            scale: s + 1,
            subScale: 0,
            scaledCoordinate: SIMD2<Int>(
                x: x,
                y: y
            ),
            absoluteCoordinate: SIMD2<Float>(
                x: Float(x) * scale.delta,
                y: Float(y) * scale.delta
            ),
            sigma: scale.sigmas[s + 1],
            value: 0
        )
        return keypoint
    }
    
    func interpolateKeypoints(commandQueue: MTLCommandQueue, keypoints: [SIFTKeypoint]) -> [SIFTKeypoint] {
        print("interpolateKeypoints")
        let sigmaRatio = scale.sigmas[1] / scale.sigmas[0]
        
        let inputBuffer = Buffer<SIFTInterpolateInputKeypoint>(
            device: device,
            label: "siftInterpiolationInputBuffer",
            count: keypoints.count
        )
        let outputBuffer = Buffer<SIFTInterpolateOutputKeypoint>(
            device: device,
            label: "siftInterpolationOutputBuffer",
            count: keypoints.count
        )
        let parametersBuffer = Buffer<SIFTInterpolateParameters>(
            device: device,
            label: "siftInterpolationParametersBuffer",
            count: 1
        )
        
        parametersBuffer[0] = SIFTInterpolateParameters(
            dogThreshold: 0.0133, // configuration.differenceOfGaussiansThreshold,
            maxIterations: 5, // Int32(configuration.maximumInterpolationIterations),
            maxOffset: 0.6,
            width: Int32(scale.size.width),
            height: Int32(scale.size.height),
            octaveDelta: scale.delta,
            edgeThreshold: 10.0, // configuration.edgeThreshold
            numberOfScales: Int32(scale.numberOfScales)
        )

        // Copy keypoints to metal buffer
        for j in 0 ..< keypoints.count {
            let keypoint = keypoints[j]
            inputBuffer[j] = SIFTInterpolateInputKeypoint(
                x: Int32(keypoint.scaledCoordinate.x),
                y: Int32(keypoint.scaledCoordinate.y),
                scale: Int32(keypoint.scale)
            )
        }
        
        //
//        let captureDescriptor = MTLCaptureDescriptor()
//        captureDescriptor.captureObject = commandQueue
//        captureDescriptor.destination = .developerTools
//        let captureManager = MTLCaptureManager.shared()
//        try! captureManager.startCapture(with: captureDescriptor)

        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "siftInterpolationCommandBuffer"

        interpolateFunction.encode(
            commandBuffer: commandBuffer,
            parameters: parametersBuffer,
            differenceTextures: scale.differenceTextures,
            inputKeypoints: inputBuffer,
            outputKeypoints: outputBuffer
        )
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
//        captureManager.stopCapture()
        
        let elapsedTime = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        print("interpolateKeypoints: Command buffer \(String(format: "%0.4f", elapsedTime)) seconds")

        //
        var output = [SIFTKeypoint]()
        for k in 0 ..< outputBuffer.count {
            let p = outputBuffer[k]
            guard p.converged != 0 else {
//                print("octave \(scale.o) keypoint \(k) not converged \(p.alphaX) \(p.alphaY) \(p.alphaZ)")
                continue
            }
//            print("octave \(scale.o) keypoint \(k) converged \(p.alphaX) \(p.alphaY) \(p.alphaZ)")

            let keypoint = SIFTKeypoint(
                octave: scale.o,
                scale: Int(p.scale),
                subScale: p.subScale,
                scaledCoordinate: SIMD2<Int>(
                    x: Int(p.relativeX),
                    y: Int(p.relativeY)
                ),
                absoluteCoordinate: SIMD2<Float>(
                    x: p.absoluteX,
                    y: p.absoluteY
                ),
                sigma: scale.sigmas[Int(p.scale)] * pow(sigmaRatio, p.subScale),
                value: p.value
            )
            output.append(keypoint)
        }
        return output
    }
    
    func getKeypointOrientations(commandQueue: MTLCommandQueue, keypoints: [SIFTKeypoint]) -> [[Float]] {
        print("getKeypointOrientations")
        let inputBuffer = Buffer<SIFTOrientationKeypoint>(
            device: device,
            label: "siftOrientationInputBuffer",
            count: keypoints.count
        )
        let outputBuffer = Buffer<SIFTOrientationResult>(
            device: device,
            label: "siftOrientationOutputBuffer",
            count: keypoints.count
        )
        let parametersBuffer = Buffer<SIFTOrientationParameters>(
            device: device,
            label: "siftOrientationParametersBuffer",
            count: 1
        )
        
        let parameters = SIFTOrientationParameters(
            delta: scale.delta,
            lambda: 1.5,
            orientationThreshold: 0.8
        )
        parametersBuffer[0] = parameters

        let minX = 1
        let minY = 1
        let maxX = scale.size.width - 2
        let maxY = scale.size.height - 2

        // Copy keypoints to metal buffer
        var i = 0
        for keypoint in keypoints {
            let x = Int((Float(keypoint.absoluteCoordinate.x) / parameters.delta).rounded())
            let y = Int((Float(keypoint.absoluteCoordinate.y) / parameters.delta).rounded())
            let sigma = keypoint.sigma / parameters.delta
            let r = Int(ceil(3 * parameters.lambda * sigma))

            // Reject keypoint outside of the image bounds
            if ((x - r) < minX) {
                continue
            }
            if ((x + r) > maxX) {
                continue
            }
            if ((y - r) < minY) {
                continue
            }
            if ((y + r) > maxY) {
                continue
            }

            inputBuffer[i] = SIFTOrientationKeypoint(
                absoluteX: Int32(keypoint.absoluteCoordinate.x),
                absoluteY: Int32(keypoint.absoluteCoordinate.y),
                scale: Int32(keypoint.scale),
                sigma: keypoint.sigma
            )
            
            i += 1
        }
        
        //
//        let captureDescriptor = MTLCaptureDescriptor()
//        captureDescriptor.captureObject = commandQueue
//        captureDescriptor.destination = .developerTools
//        let captureManager = MTLCaptureManager.shared()
//        try! captureManager.startCapture(with: captureDescriptor)
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "siftOrientationCommandBuffer"
        
        orientationFunction.encode(
            commandBuffer: commandBuffer,
            parameters: parametersBuffer,
            gradientTextures: gradientTextures,
            inputKeypoints: inputBuffer,
            outputKeypoints: outputBuffer
        )
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
//        captureManager.stopCapture()
        
        let elapsedTime = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        print("getKeypointOrientations: Command buffer \(String(format: "%0.4f", elapsedTime)) seconds")

        //
        var output = [[Float]]()
        for k in 0 ..< outputBuffer.count {
            var result = outputBuffer[k]
            let count = Int(result.count)
            var orientations = Array<Float>(repeating: 0, count: count)
            withUnsafePointer(to: &result.orientations) { p in
                let p = UnsafeRawPointer(p).assumingMemoryBound(to: Float.self)
                for i in 0 ..< count {
                    orientations[i] = p[i]
                }
            }
            output.append(orientations)
        }
        print("getKeypointOrientations: \(output.joined().count) orientations")
        return output
    }
    
    func getDescriptors(commandQueue: MTLCommandQueue, keypoints: [SIFTKeypoint], orientations: [[Float]]) -> [SIFTDescriptor] {
        
        let descriptorCount = orientations.joined().count
        
        guard descriptorCount > 0 else {
            return []
        }
        
        let inputBuffer = Buffer<SIFTDescriptorInput>(
            device: device,
            label: "siftDescriptorsInputBuffer",
            count: descriptorCount
        )
        let outputBuffer = Buffer<SIFTDescriptorResult>(
            device: device,
            label: "siftDescriptorsOutputBuffer",
            count: descriptorCount
        )
        let parametersBuffer = Buffer<SIFTDescriptorParameters>(
            device: device,
            label: "siftDescriptorsParametersBuffer",
            count: 1
        )
        
        let parameters = SIFTDescriptorParameters(
            delta: scale.delta,
            scalesPerOctave: 3,
            width: Int32(scale.size.width),
            height: Int32(scale.size.height)
        )
        parametersBuffer[0] = parameters

//        let minX = 1
//        let minY = 1
//        let maxX = scale.size.width - 2
//        let maxY = scale.size.height - 2

        // Copy keypoints to metal buffer
        var i = 0
        for j in 0 ..< keypoints.count {
            let keypoint = keypoints[j]
            let orientations = orientations[j]
            for orientation in orientations {
                inputBuffer[i] = SIFTDescriptorInput(
                    keypoint: Int32(j),
                    absoluteX: Int32(keypoint.absoluteCoordinate.x),
                    absoluteY: Int32(keypoint.absoluteCoordinate.y),
                    scale: Int32(keypoint.scale),
                    subScale: keypoint.subScale,
                    theta: orientation
                )
                i += 1
            }
//            #warning("TODO: Discard keypoint if it is too close to the boundary")
//            let x = Int((Float(keypoint.absoluteCoordinate.x) / parameters.delta).rounded())
//            let y = Int((Float(keypoint.absoluteCoordinate.y) / parameters.delta).rounded())
//            let sigma = keypoint.sigma / parameters.delta
//            let r = Int(ceil(3 * parameters.lambda * sigma))
//
//            // Reject keypoint outside of the image bounds
//            if ((x - r) < minX) {
//                continue
//            }
//            if ((x + r) > maxX) {
//                continue
//            }
//            if ((y - r) < minY) {
//                continue
//            }
//            if ((y + r) > maxY) {
//                continue
//            }
        }
        
        //
//        let captureDescriptor = MTLCaptureDescriptor()
//        captureDescriptor.captureObject = commandQueue
//        captureDescriptor.destination = .developerTools
//        let captureManager = MTLCaptureManager.shared()
//        try! captureManager.startCapture(with: captureDescriptor)

        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "siftDescriptorsCommandBuffer"
        
        descriptorFunction.encode(
            commandBuffer: commandBuffer,
            parameters: parametersBuffer,
            gradientTextures: gradientTextures,
            inputKeypoints: inputBuffer,
            outputDescriptors: outputBuffer
        )
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
//        captureManager.stopCapture()
        let elapsedTime = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        print("getDescriptors: Command buffer \(String(format: "%0.4f", elapsedTime)) seconds")

        //
        let numberOfFeatures = 128
        var output = [SIFTDescriptor]()
        for k in 0 ..< descriptorCount {
            var result = outputBuffer[k]
            let keypoint = keypoints[Int(result.keypoint)]
            let theta = result.theta
            var features = Array<Int>(repeating: 0, count: numberOfFeatures)
            withUnsafePointer(to: &result.features) { p in
                let p = UnsafeRawPointer(p).assumingMemoryBound(to: Int32.self)
                for i in 0 ..< numberOfFeatures {
                    features[i] = Int(p[i])
                }
            }
            let descriptor = SIFTDescriptor(
                keypoint: keypoint,
                theta: theta,
                rawFeatures: [],
                features: features
            )
            output.append(descriptor)
        }
        print("getDescriptors: \(output.count) descriptors")
        return output
    }
}
