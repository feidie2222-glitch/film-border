import Foundation
import CoreImage
import CoreGraphics

struct EngineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func render() throws {
    let args = CommandLine.arguments
    guard args.count == 5 else { throw EngineFailure(message: "引擎参数不完整") }
    let inputURL = URL(fileURLWithPath: args[1])
    let outputURL = URL(fileURLWithPath: args[2])
    let params = args[3]
    let resources = args[4]
    guard let image = CIImage(contentsOf: inputURL), let romm = CGColorSpace(name: CGColorSpace.rommrgb),
          let linear = CGColorSpaceCreateLinearized(romm), let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw EngineFailure(message: "无法读取图片或色彩空间")
    }
    let bounds = image.extent.integral
    let width = Int(bounds.width), height = Int(bounds.height)
    guard width > 0, height > 0, width * height <= 60_000_000 else { throw EngineFailure(message: "图片尺寸不受支持") }
    let context = CIContext(options: [.workingColorSpace: linear])
    var pixels = [Float](repeating: 0, count: width * height * 4)
    context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: linear)
    guard let engine = resources.withCString({ spk_engine_create($0, nil) }) else { throw EngineFailure(message: "无法启动 Metal 引擎") }
    defer { spk_engine_destroy(engine) }
    func check(_ status: Int32) throws {
        guard status == 0 else { throw EngineFailure(message: String(cString: spk_last_error(engine))) }
    }
    var response: UnsafeMutablePointer<CChar>?
    let session = pixels.withUnsafeBufferPointer { buffer in
        var source = spk_image(data: buffer.baseAddress, width: UInt32(width), height: UInt32(height), channels: 4)
        return params.withCString { spk_open(engine, &source, $0, &response) }
    }
    if let response { spk_string_free(response) }
    guard let session else { throw EngineFailure(message: String(cString: spk_last_error(engine))) }
    defer { spk_session_release(session) }
    var result = spk_result()
    try check(spk_render(session, "full", &result))
    defer { spk_result_free(&result) }
    guard let data = result.rgba16 else { throw EngineFailure(message: "引擎未返回图片") }
    let bytesPerRow = Int(result.row_stride_px) * 8
    let bytes = Data(bytes: data, count: bytesPerRow * Int(result.height))
    let rendered = CIImage(bitmapData: bytes, bytesPerRow: bytesPerRow,
        size: CGSize(width: Int(result.width), height: Int(result.height)), format: .RGBA16, colorSpace: romm)
    guard let png = context.pngRepresentation(of: rendered, format: .RGBA8, colorSpace: srgb) else {
        throw EngineFailure(message: "无法生成边框图片")
    }
    try png.write(to: outputURL, options: .atomic)
    var geometry: UnsafeMutablePointer<CChar>?
    try check(spk_overscan_geometry(session, &geometry))
    guard let geometry else { throw EngineFailure(message: "引擎未返回片门位置") }
    defer { spk_string_free(geometry) }
    let geometryData = Data(String(cString: geometry).utf8)
    guard let geometryObject = try JSONSerialization.jsonObject(with: geometryData) as? [String: Any],
          let gates = geometryObject["gates"] as? [[Double]], let gate = gates.first else {
        throw EngineFailure(message: "无法读取片门位置")
    }
    let json = try JSONSerialization.data(withJSONObject: ["width": Int(result.width), "height": Int(result.height), "gate": gate])
    FileHandle.standardOutput.write(json)
}

do { try render() } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
