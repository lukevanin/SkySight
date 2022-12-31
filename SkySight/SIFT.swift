//
//  SIFT.swift
//  SkySight
//
//  Created by Luke Van In on 2022/12/18.
//

import Foundation
import OSLog
import Metal
import MetalPerformanceShaders


private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "SIFT"
)


struct SIFTKeypoint {
    var octave: Int
    var scale: Int
    var scaledCoordinate: SIMD2<Int>
    var absoluteCoordinate: SIMD2<Int>
    var sigma: Float
    var value: Float
}


final class SIFTOctave {
    
    let scale: DifferenceOfGaussians.Octave
    
    let keypointTextures: [MTLTexture]
    let images: [Image<SIMD2<Float>>]
    
    private let extremaFunction: SIFTExtremaFunction
    
    init(
        device: MTLDevice,
        scale: DifferenceOfGaussians.Octave,
        extremaFunction: SIFTExtremaFunction
    ) {
        
        let textureDescriptor: MTLTextureDescriptor = {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg32Float,
                width: scale.size.width,
                height: scale.size.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return descriptor
        }()
        
        let keypointTextures = {
            var textures = [MTLTexture]()
            for _ in 0 ..< scale.numberOfScales {
                let texture = device.makeTexture(
                    descriptor: textureDescriptor
                )!
                textures.append(texture)
            }
            return textures
        }()
        
        self.scale = scale
        self.extremaFunction = extremaFunction
        self.keypointTextures = keypointTextures
        self.images = {
            var images = [Image<SIMD2<Float>>]()
            for texture in keypointTextures {
                let image = Image<SIMD2<Float>>(texture: texture, defaultValue: .zero)
                images.append(image)
            }
            return images
        }()
    }
    
    func encode(commandBuffer: MTLCommandBuffer) {
        for i in 0 ..< keypointTextures.count {
            extremaFunction.encode(
                commandBuffer: commandBuffer,
                inputTexture0: scale.differenceTextures[i + 0],
                inputTexture1: scale.differenceTextures[i + 1],
                inputTexture2: scale.differenceTextures[i + 2],
                outputTexture: keypointTextures[i]
            )
        }
    }
    
    func getKeypoints() -> [SIFTKeypoint] {
        updateImagesFromTextures()
        updateImagesFromTextures()
        return getKeypointsFromImages()
    }
    
    private func updateImagesFromTextures() {
        for image in images {
            image.updateFromTexture()
        }
    }

    private func getKeypointsFromImages() -> [SIFTKeypoint] {
        var keypoints = [SIFTKeypoint]()
        for s in 0 ..< images.count {
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
        let image = images[s]
        let output = image[x, y]
        let extrema = output[0] == 1
        let value = output[1]

        if extrema == false {
            return nil
        }

        let keypoint = SIFTKeypoint(
            octave: scale.o,
            scale: s + 1,
            scaledCoordinate: SIMD2<Int>(
                x: x,
                y: y
            ),
            absoluteCoordinate: SIMD2<Int>(
                x: Int(Float(x) * scale.delta),
                y: Int(Float(y) * scale.delta)
            ),
            sigma: scale.sigmas[s + 1],
            value: value
        )
        return keypoint
    }
}


/// See: http://www.ipol.im/pub/art/2014/82/article.pdf
/// See: https://medium.com/jun94-devpblog/cv-13-scale-invariant-local-feature-extraction-3-sift-315b5de72d48
final class SIFT {
    
    struct Configuration {
        
        // Dimensions of the input image.
        var inputSize: IntegralSize
        
        // Threshold over the Difference of Gaussians response (value
        // relative to scales per octave = 3)
        var differenceOfGaussiansThreshold: Float = 0.0133 // 0.015
        
        // Threshold over the ratio of principal curvatures (edgeness).
        var edgeThreshold: Float = 10.0
        
        // Maximum number of consecutive unsuccessful interpolation.
        var maximumInterpolationIterations: Int = 5
        
        // Width of border in which to ignore keypoints
        var imageBorder: Int = 5
    }

    let configuration: Configuration
    let dog: DifferenceOfGaussians
    let octaves: [SIFTOctave]
    
    private let commandQueue: MTLCommandQueue
    
    init(
        device: MTLDevice,
        configuration: Configuration
    ) {
        let dog = DifferenceOfGaussians(
            device: device,
            configuration: DifferenceOfGaussians.Configuration(
                inputDimensions: configuration.inputSize
            )
        )
        let octaves: [SIFTOctave] = {
            let extremaFunction = SIFTExtremaFunction(device: device)
            
            var octaves = [SIFTOctave]()
            for scale in dog.octaves {
                let octave = SIFTOctave(
                    device: device,
                    scale: scale,
                    extremaFunction: extremaFunction
                )
                octaves.append(octave)
            }
            return octaves
        }()
        
        self.commandQueue = device.makeCommandQueue()!
        self.configuration = configuration
        self.dog = dog
        self.octaves = octaves
    }
    
    func getKeypoints(_ inputTexture: MTLTexture) -> [SIFTKeypoint] {
        findKeypoints(inputTexture: inputTexture)
        let allKeypoints = getKeypointsFromOctaves()
        let softThreshold = configuration.differenceOfGaussiansThreshold * 0.8
        let candidateKeypoints = allKeypoints.filter {
            abs($0.value) > softThreshold
        }
        let interpolatedKeypoints = interpolateKeypoints(
            keypoints: candidateKeypoints
        )
        return interpolatedKeypoints
    }
    
    private func findKeypoints(inputTexture: MTLTexture) {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        dog.encode(
            commandBuffer: commandBuffer,
            originalTexture: inputTexture
        )
        
        for octave in octaves {
            octave.encode(
                commandBuffer: commandBuffer
            )
        }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let elapsedTime = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        print("Command buffer", String(format: "%0.3f", elapsedTime), "seconds")
    }
    
    private func getKeypointsFromOctaves() -> [SIFTKeypoint] {
        var keypoints = [SIFTKeypoint]()
        for octave in octaves {
            keypoints.append(contentsOf: octave.getKeypoints())
        }
        return keypoints
    }

    private func interpolateKeypoints(keypoints: [SIFTKeypoint]) -> [SIFTKeypoint] {
        var interpolatedKeypoints = [SIFTKeypoint]()
        
        for octave in dog.octaves {
            for image in octave.differenceImages {
                image.updateFromTexture()
            }
        }
        
        for i in 0 ..< keypoints.count {
            let keypoint = keypoints[i]
            let interpolatedKeypoint = interpolateKeypoint(keypoint: keypoint)
            if let interpolatedKeypoint {
                interpolatedKeypoints.append(interpolatedKeypoint)
            }
        }
        return interpolatedKeypoints
    }
    
    private func interpolateKeypoint(keypoint: SIFTKeypoint) -> SIFTKeypoint? {
        
        // Note: x and y are swapped in the original algorithm.
        
        // Maximum number of consecutive unsuccessful interpolation.
        let maximumIterations: Int = configuration.maximumInterpolationIterations
        
        let maximumOffset: Float = 0.6
        
        // Ratio between two consecutive scales in the scalespace assuming the
        // ratio is constant over all scales and over all octaves.
        let sigmaRatio = dog.octaves[0].sigmas[1] / dog.octaves[0].sigmas[0]
        
        let o: Int = keypoint.octave
        let s: Int = keypoint.scale
        let x: Int = keypoint.scaledCoordinate.x
        let y: Int = keypoint.scaledCoordinate.y
        let octave: DifferenceOfGaussians.Octave = dog.octaves[o]
//        let w: Int = octave.size.width
//        let h: Int = octave.size.height
//        let ns: Int = octave.numberOfScales
        let delta: Float = octave.delta
        let images: [Image<Float>] = octave.differenceImages
//        let value: Float = keypoint.value
        
        var coordinate = SIMD3<Int>(x: x, y: y, z: s)
        
        // Check coordinates are within the scale space.
        guard !outOfBounds(octave: octave, coordinate: coordinate) else {
            print("out of bounds coordinate=\(coordinate)")
            return nil
        }

        var converged = false
        var alpha: SIMD3<Float> = .zero
        
        var i = 0
        while i < maximumIterations {
            alpha = interpolationStep(images: images, coordinate: coordinate)
            
            if (abs(alpha.x) < maximumOffset) && (abs(alpha.y) < maximumOffset) && (abs(alpha.z) < maximumOffset) {
                converged = true
                break
            }
            
            coordinate.x += Int(alpha.x.rounded())
            coordinate.y += Int(alpha.y.rounded())
            coordinate.z += Int(alpha.z.rounded())
            
            // Check coordinates are within the scale space.
            guard !outOfBounds(octave: octave, coordinate: coordinate) else {
                print("out of bounds coordinate=\(coordinate)")
                return nil
            }
            
            i += 1
        }
        
        guard converged == true else {
            return nil
        }
        
        let newValue = interpolateContrast(i: images, c: coordinate, alpha: alpha)

        print("point converged \(i) out of \(maximumIterations): coordinate=\(coordinate) alpha=\(alpha) value=\(newValue)")

        
//        var iterationCount: Int = 0 // nIntrp
//        var isConverged = false
//        var interpolation = Interpolation(dx: 0, dy: 0, ds: 0, value: value)

//        while iterationCount < maximumIterations {
//
//            // Extrema interpolation via a quadratic function
//            // Only if the detection is not too close to the border (so the
//            // discrete 3D Hessian is well defined).
//            guard (ic > 0) && (ic < (w - 1)) && (jc > 0) && (jc < (h - 1)) else {
//                break
//            }
//            let x = inverseTaylorSecondOrderExpansion(images: images, x: ic, y: jc, s: sc)
//            interpolation = x
//
//            if (abs(interpolation.dx) < maximumOffset) && (abs(interpolation.dy) < maximumOffset) && (abs(interpolation.ds) < maximumOffset) {
//                isConverged = true
//                break
//            }
//            else {
//                if (interpolation.dx > +maximumOffset) && ((ic + 1) < (w - 1)) {
//                    ic += 1
//                }
//                if (interpolation.dx < -maximumOffset) && ((ic - 1) > 0) {
//                    ic -= 1
//                }
//                if (interpolation.dy > +maximumOffset) && ((jc + 1) < (h - 1)) {
//                    jc += 1
//                }
//                if (interpolation.dy < -maximumOffset) && ((jc - 1) > 0) {
//                    jc -= 1
//                }
//                if (interpolation.ds > +maximumOffset) && ((sc + 1) < (ns - 1)) {
//                    sc += 1
//                }
//                if (interpolation.ds < -maximumOffset) && ((sc - 1) > 0) {
//                    sc -= 1
//                }
//            }
//
//            iterationCount += 1
//        }
//
//        guard isConverged else {
//            print("point rejected \(iterationCount) / \(maximumIterations)")
//            return nil
//        }
//
        return SIFTKeypoint(
            octave: keypoint.octave,
            scale: s,
            scaledCoordinate: SIMD2<Int>(
                x: Int((Float(x) + alpha.x).rounded()),
                y: Int((Float(y) + alpha.y).rounded())
            ),
            absoluteCoordinate: SIMD2<Int>(
                x: Int(((Float(x) + alpha.x) * delta).rounded()),
                y: Int(((Float(y) + alpha.y) * delta).rounded())
            ),
            sigma: octave.sigmas[s] * pow(sigmaRatio, alpha.z),
            value: newValue
        )
    }
    
//    struct Interpolation {
//        var dx: Float
//        var dy: Float
//        var ds: Float
//        var value: Float
//    }
    
    private func outOfBounds(octave: DifferenceOfGaussians.Octave, coordinate: SIMD3<Int>) -> Bool {
        let minX = configuration.imageBorder
        let maxX = octave.size.width - configuration.imageBorder - 1
        let minY = configuration.imageBorder
        let maxY = octave.size.height - configuration.imageBorder - 1
        let minS = 1
        let maxS = octave.numberOfScales
        return coordinate.x < minX || coordinate.x > maxX || coordinate.y < minY || coordinate.y > maxY || coordinate.z < minS || coordinate.z > maxS
    }
    
    private func interpolationStep(
        images: [Image<Float>],
        coordinate: SIMD3<Int>
    ) -> SIMD3<Float> {
        
        let H = hessian3D(i: images, c: coordinate)
        precondition(H.determinant != 0)
        let Hi = H.inverse
        
        let dD = derivatives3D(i: images, c: coordinate)
        
        let x = Hi * dD
        
        return x
    }
    
    ///
    /// Computes the 3D Hessian matrix.
    ///
    ///```
    ///  ⎡ Ixx Ixy Ixs ⎤
    ///
    ///    Ixy Iyy Iys
    ///
    ///  ⎣ Ixs Iys Iss ⎦
    /// ```
    ///
    private func hessian3D(i: [Image<Float>], c: SIMD3<Int>) -> matrix_float3x3 {
        let v = i[c.z][c.x, c.y]
        
        let dxx = i[c.z][c.x + 1, c.y] + i[c.z][c.x - 1, c.y] - 2 * v
        let dyy = i[c.z][c.x, c.y + 1] + i[c.z][c.x, c.y - 1] - 2 * v
        let dss = i[c.z + 1][c.x, c.y] + i[c.z - 1][c.x, c.y] - 2 * v

        let dxy = (i[c.z][c.x + 1, c.y + 1] - i[c.z][c.x - 1, c.y + 1] - i[c.z][c.x + 1, c.y - 1] + i[c.z][c.x - 1, c.y - 1]) * 0.25
        let dxs = (i[c.z + 1][c.x + 1, c.y] - i[c.z + 1][c.x - 1, c.y] - i[c.z - 1][c.x + 1, c.y] + i[c.z - 1][c.x - 1, c.y]) * 0.25
        let dys = (i[c.z + 1][c.x, c.y + 1] - i[c.z + 1][c.x, c.y - 1] - i[c.z - 1][c.x, c.y + 1] + i[c.z - 1][c.x, c.y - 1]) * 0.25
        
        return matrix_float3x3(
            rows: [
                SIMD3<Float>(dxx, dxy, dxs),
                SIMD3<Float>(dxy, dyy, dys),
                SIMD3<Float>(dxs, dys, dss),
            ]
        )
    }
    
    ///
    /// Computes interpolated contrast. Based on Eqn. (3) in Lowe's paper.
    ///
    func interpolateContrast(i: [Image<Float>], c: SIMD3<Int>, alpha: SIMD3<Float>) -> Float {
        let dD = derivatives3D(i: i, c: c)
        let t = dD * alpha
        let v = i[c.z][c.x, c.y] + t.x * 0.5
        return v
    }
    
    ///
    /// Computes the partial derivatives in x, y, and scale of a pixel in the DoG scale space pyramid.
    ///
    /// - Returns: Returns the vector of partial derivatives for pixel I { dI/dX, dI/dY, dI/ds }ᵀ
    ///
    private func derivatives3D(i: [Image<Float>], c: SIMD3<Int>) -> SIMD3<Float> {
        return SIMD3<Float>(
            x: (i[c.z][c.x + 1, c.y] - i[c.z][c.x - 1, c.y]) * 0.5,
            y: (i[c.z][c.x, c.y + 1] - i[c.z][c.x, c.y - 1]) * 0.5,
            z: (i[c.z + 1][c.x, c.y] - i[c.z - 1][c.x, c.y]) * 0.5
        )
    }

}
