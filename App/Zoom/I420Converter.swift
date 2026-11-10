//
//  I420Converter.swift
//  Greenroom
//
//  Turns a BGRA picture into the I420 the Zoom SDK is given, at the size the
//  SDK asked for. No Zoom code in here, so it can be compiled and measured on
//  its own (docs/drop-obs-plan.md, piece 2).
//
//  Everything is allocated once in `init`; `convert` allocates nothing.
//  The picture keeps its shape: if the target is not the same shape as the
//  source it is scaled to fit and centred, with black bars (never stretched,
//  never cropped). Output is BT.601 video range, which is what
//  `ZoomSDKFrameDataFormat_I420_Limited` means.
//

import Accelerate
import Foundation

final class I420Converter {
    let sourceWidth: Int, sourceHeight: Int
    let width: Int, height: Int
    /// The picture's size inside the output, and where its top left sits.
    let fitWidth: Int, fitHeight: Int, offsetX: Int, offsetY: Int

    var isLetterboxed: Bool { fitWidth != width || fitHeight != height }
    var needsScale: Bool { fitWidth != sourceWidth || fitHeight != sourceHeight }
    /// Bytes in one finished frame: w * h * 3 / 2.
    var byteCount: Int { width * height * 3 / 2 }

    private let canvas: UnsafeMutableRawPointer?   // BGRA at output size, only when scaling
    private let temp: UnsafeMutableRawPointer?     // vImage scratch
    private let yuv: UnsafeMutableRawPointer
    private var info = vImage_ARGBToYpCbCr()
    private var ready = false

    /// Output sizes are rounded down to even (I420 needs it).
    init(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int) {
        let sw = max(2, sourceWidth), sh = max(2, sourceHeight)
        let w = max(2, width & ~1), h = max(2, height & ~1)
        self.sourceWidth = sw; self.sourceHeight = sh
        self.width = w; self.height = h
        let fit = Self.fit(sourceWidth: sw, sourceHeight: sh, width: w, height: h)
        (fitWidth, fitHeight, offsetX, offsetY) = fit

        yuv = .allocate(byteCount: w * h * 3 / 2, alignment: 64)
        // Black in video range: Y 16, Cb and Cr 128. Sent as is until a real frame is converted.
        memset(yuv, 16, w * h)
        memset(yuv + w * h, 128, w * h / 2)

        if fit.0 != sw || fit.1 != sh {
            let c = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
            // Opaque black BGRA; the scaler only ever writes inside the fitted rectangle.
            var black: UInt32 = 0xFF00_0000
            memset_pattern4(c, &black, w * h * 4)
            canvas = c
            var s = vImage_Buffer(data: nil, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw * 4)
            var d = vImage_Buffer(data: nil, height: vImagePixelCount(fit.1), width: vImagePixelCount(fit.0), rowBytes: w * 4)
            let need = vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageGetTempBufferSize))
            temp = need > 0 ? .allocate(byteCount: need, alignment: 64) : nil
        } else {
            canvas = nil; temp = nil
        }

        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        let err = vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info, kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags))
        ready = (err == kvImageNoError)
    }

    deinit {
        canvas?.deallocate(); temp?.deallocate(); yuv.deallocate()
    }

    /// Largest even-sized rectangle of the source's shape that fits the output, centred.
    static func fit(sourceWidth sw: Int, sourceHeight sh: Int, width: Int, height: Int) -> (Int, Int, Int, Int) {
        var fw: Int, fh: Int
        if width * sh <= height * sw {            // wider than the output: fill the width
            fw = width; fh = Int((Double(width) * Double(sh) / Double(sw)).rounded())
        } else {
            fh = height; fw = Int((Double(height) * Double(sw) / Double(sh)).rounded())
        }
        fw = min(width, max(2, fw & ~1)); fh = min(height, max(2, fh & ~1))
        // Within a few pixels of the output's shape is not worth bars.
        if abs(fw - width) <= 2 && abs(fh - height) <= 2 { fw = width; fh = height }
        return (fw, fh, ((width - fw) / 2) & ~1, ((height - fh) / 2) & ~1)
    }

    /// Converts one BGRA frame (row 0 is the top). Returns the I420 bytes,
    /// valid until the next call, or nil if the conversion failed.
    func convert(_ src: UnsafeRawPointer, rowBytes: Int) -> UnsafeMutableRawPointer? {
        guard ready else { return nil }
        var srcBuf: vImage_Buffer
        if let canvas {
            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(sourceHeight), width: vImagePixelCount(sourceWidth), rowBytes: rowBytes)
            var d = vImage_Buffer(data: canvas + offsetY * width * 4 + offsetX * 4, height: vImagePixelCount(fitHeight), width: vImagePixelCount(fitWidth), rowBytes: width * 4)
            guard vImageScale_ARGB8888(&s, &d, temp, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
            srcBuf = vImage_Buffer(data: canvas, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        } else {
            srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        }
        var yBuf = vImage_Buffer(data: yuv, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var cbBuf = vImage_Buffer(data: yuv + width * height, height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var crBuf = vImage_Buffer(data: yuv + width * height + (width / 2) * (height / 2), height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width / 2)
        var permute: [UInt8] = [3, 2, 1, 0] // BGRA in memory -> ARGB
        let err = vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&srcBuf, &yBuf, &cbBuf, &crBuf, &info, &permute, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError ? yuv : nil
    }

    /// The black frame, for before any picture has arrived.
    var blackFrame: UnsafeMutableRawPointer { yuv }
}

/// Which of the SDK's offered sizes to use for a 16:9 source.
enum StageVideoSizing {
    struct Choice: Equatable { var width: Int; var height: Int; var fps: Int }

    static func isSixteenNine(_ c: Choice) -> Bool { c.width * 9 == c.height * 16 }

    /// The suggestion, letterboxed if it is not 16:9. A 16:9 size is chosen
    /// instead only when its picture is at least as large as the letterboxed
    /// picture inside the suggestion (the smallest such size, to keep the cost
    /// down). `reason` is plain words for the log.
    static func choose(supported: [Choice], suggested: Choice?) -> (choice: Choice, reason: String) {
        let evened: (Choice) -> Choice = { Choice(width: max(2, $0.width & ~1), height: max(2, $0.height & ~1), fps: max(1, $0.fps)) }
        guard let suggested else { return (Choice(width: 640, height: 360, fps: 30), "the SDK gave no suggestion, so 640x360 at 30") }
        let sug = evened(suggested)
        if isSixteenNine(sug) { return (sug, "the SDK's suggested size is 16:9") }
        let box = I420Converter.fit(sourceWidth: 16, sourceHeight: 9, width: sug.width, height: sug.height)
        let boxArea = box.0 * box.1
        let better = supported.map(evened).filter { isSixteenNine($0) && $0.width * $0.height >= boxArea }
            .min { $0.width * $0.height < $1.width * $1.height }
        if let better {
            return (better, "the suggested \(sug.width)x\(sug.height) is not 16:9 and would carry a \(box.0)x\(box.1) picture; this 16:9 size carries a picture at least as large, with no black bars")
        }
        return (sug, "the suggested \(sug.width)x\(sug.height) is not 16:9; no 16:9 size carries a picture as large as the \(box.0)x\(box.1) one inside it, so it is letterboxed with black bars")
    }
}
