import Foundation

/// A minimal well-formed PNG: signature + padding + a zero-length IEND
/// chunk. `CapturePublisher` checks framing, not decodability, so this is
/// enough to satisfy it without a real encoder. The one definition here is
/// shared by `CapturePublisherTests` and `ScreenshotServiceTests` so the
/// test tree has a single notion of "a valid PNG" — a capturer double that
/// returns bytes no PNG decoder would accept was always a hole, which is
/// why a 4-byte capture file could ship for months without a unit test
/// noticing.
func validPNG(padding: Int = 0) -> Data {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    data.append(Data(repeating: 0x41, count: padding))
    data.append(Data([0x00, 0x00, 0x00, 0x00]))
    data.append(Data("IEND".utf8))
    data.append(Data([0xAE, 0x42, 0x60, 0x82]))
    return data
}
