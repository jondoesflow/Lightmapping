import AVFoundation
import CoreImage
import CoreML
import ImageIO
import UIKit
import Vision

/// Turns a single photo into a mappable shape: a subject silhouette mask, and for
/// depth mode a per-pixel depth map aligned to it.
///
/// Depth comes from, in order of preference:
/// 1. Depth/disparity embedded in the photo (Portrait mode / LiDAR captures).
/// 2. A bundled monocular depth Core ML model named `DepthModel` (for example Apple's
///    Depth Anything V2 Small conversion, renamed), if one is added to the app target.
/// 3. A synthetic "inflated" depth built from the silhouette's distance-to-edge,
///    which gives a convincing rounded relief for depth-aware effects.
enum ShapeExtractor {
    struct Result {
        var mask: UIImage
        var depth: UIImage?
        var aspect: Float
        var depthSource: String
    }

    enum ExtractError: LocalizedError {
        case unreadable, noSubject
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The image couldn't be read."
            case .noSubject: return "No subject was found in this photo. Try one with a clear foreground object."
            }
        }
    }

    private static let ciContext = CIContext()

    static func extract(from data: Data, wantDepth: Bool) async throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExtractError.unreadable }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        let cgOrientation = CGImagePropertyOrientation(rawValue: orientation ?? 1) ?? .up
        let upright = CIImage(cgImage: cg).oriented(cgOrientation)
        guard let uprightCG = ciContext.createCGImage(upright, from: upright.extent) else { throw ExtractError.unreadable }

        let maskCI = try subjectMask(uprightCG)
        guard let maskImage = ciContext.createCGImage(maskCI, from: upright.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { throw ExtractError.noSubject }

        var depthImage: UIImage?
        var depthSource = "none"
        if wantDepth {
            if let d = embeddedDepth(source, orientation: cgOrientation, extent: upright.extent) {
                depthImage = d; depthSource = "Embedded photo depth"
            } else if let d = modelDepth(uprightCG, extent: upright.extent) {
                depthImage = d; depthSource = "Core ML depth model"
            } else {
                depthImage = syntheticDepth(mask: maskCI, extent: upright.extent); depthSource = "Shape relief (estimated)"
            }
        }
        return Result(mask: UIImage(cgImage: maskImage), depth: depthImage,
                      aspect: Float(upright.extent.width / upright.extent.height), depthSource: depthSource)
    }

    /// Foreground subject mask, scaled to the source image size.
    private static func subjectMask(_ image: CGImage) throws -> CIImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        if let obs = request.results?.first, !obs.allInstances.isEmpty {
            let pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            return CIImage(cvPixelBuffer: pb)
        }
        // Fall back to person segmentation (works on older content where instance masks fail).
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        try handler.perform([person])
        guard let pb = person.results?.first?.pixelBuffer else { throw ExtractError.noSubject }
        let ci = CIImage(cvPixelBuffer: pb)
        let sx = CGFloat(image.width) / ci.extent.width, sy = CGFloat(image.height) / ci.extent.height
        return ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    private static func embeddedDepth(_ source: CGImageSource, orientation: CGImagePropertyOrientation, extent: CGRect) -> UIImage? {
        let types = [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth]
        for type in types {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { continue }
            if depth.depthDataType != kCVPixelFormatType_DisparityFloat32 {
                depth = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            }
            // Disparity is larger when nearer, which is what we want (white = near).
            let ci = CIImage(cvPixelBuffer: depth.depthDataMap).oriented(orientation)
            return normalized(ci, to: extent)
        }
        return nil
    }

    private static func modelDepth(_ image: CGImage, extent: CGRect) -> UIImage? {
        guard let url = Bundle.main.url(forResource: "DepthModel", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url), let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let obs = request.results?.first as? VNPixelBufferObservation else { return nil }
        return normalized(CIImage(cvPixelBuffer: obs.pixelBuffer), to: extent)
    }

    /// Distance-to-edge relief: repeatedly blurred mask, masked back to the silhouette.
    private static func syntheticDepth(mask: CIImage, extent: CGRect) -> UIImage? {
        let radius = max(extent.width, extent.height) * 0.04
        var acc = mask
        for i in 1...3 {
            acc = acc.clampedToExtent()
                .applyingGaussianBlur(sigma: radius * Double(i))
                .cropped(to: extent)
        }
        let relief = acc.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        return normalized(relief, to: extent)
    }

    /// Scale to `extent`, then stretch values to the full 0...1 range as 8-bit grey.
    private static func normalized(_ image: CIImage, to extent: CGRect) -> UIImage? {
        let sx = extent.width / image.extent.width, sy = extent.height / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: extent)
        guard let minMax = minMax(scaled) else { return nil }
        let range = max(minMax.1 - minMax.0, 1e-5)
        let stretched = scaled.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / range, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1 / range, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1 / range, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -minMax.0 / range, y: -minMax.0 / range, z: -minMax.0 / range, w: 1),
        ])
        guard let cg = ciContext.createCGImage(stretched, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func minMax(_ image: CIImage) -> (CGFloat, CGFloat)? {
        guard let filter = CIFilter(name: "CIAreaMinMaxRed", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)]),
              let out = filter.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        // R and G hold the two extremes; order them explicitly rather than rely on channel order.
        return (CGFloat(min(px[0], px[1])), CGFloat(max(px[0], px[1])))
    }
}
