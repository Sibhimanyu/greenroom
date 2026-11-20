//
//  MainPersonSelector.swift
//  Greenroom
//
//  Vision calls every person-shaped region a person. A static object at the
//  edge of one camera's view can come back as a sliced fragment that sits
//  next to the presenter for the whole recording. This keeps only the MAIN
//  person in a mask: the biggest blob, weighted towards the centre, held
//  steady across frames, plus any blob that touches the main blob's
//  neighbourhood (a raised hand, an arm, a held object).
//
//  Foundation only, so the tests compile it. It runs on the mask at its
//  native low resolution, every frame, so it is one labelling pass over an
//  8-bit buffer with scratch memory that is reused between frames.
//

import Foundation

final class MainPersonSelector {

    /// A pixel at or above this belongs to a blob.
    let threshold: UInt8
    /// Blobs smaller than this share of the mask are specks: never the main
    /// blob, never kept.
    let minAreaFraction: Double
    /// How far past the main blob's box (as a share of its size) a blob may
    /// sit and still count as part of the person.
    let margin: Double
    /// Another blob must score this many times the one nearest the previous
    /// frame's main blob before the choice moves.
    let switchRatio: Double

    private var capacity = 0
    private var labels = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var parent = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var area = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var minX = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var maxX = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var minY = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var maxY = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var sumX = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var sumY = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// 1 = keep, 0 = drop (indexed by root label).
    private var keep = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

    /// Previous frame's main-blob centroid, as fractions of the mask.
    private var previous: (x: Double, y: Double)?

    init(threshold: UInt8 = 32, minAreaFraction: Double = 0.0025,
         margin: Double = 0.3, switchRatio: Double = 1.6) {
        self.threshold = threshold
        self.minAreaFraction = minAreaFraction
        self.margin = margin
        self.switchRatio = switchRatio
    }

    deinit { free() }

    /// Forget the previous frame (the camera was turned off or nobody is in
    /// view).
    func reset() { previous = nil }

    /// Convenience for tests: a tightly packed mask.
    func select(_ mask: inout [UInt8], width: Int, height: Int) {
        guard mask.count >= width * height, width > 0, height > 0 else { return }
        mask.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            select(base, width: width, height: height, bytesPerRow: width)
        }
    }

    /// Erases everything that is not the main person, in place. A mask with
    /// no blob big enough is left exactly as it is.
    func select(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        let count = width * height
        guard count > 0 else { return }
        reserve(count)
        labels.update(repeating: 0, count: count)

        // Pass 1: label with union-find (4-connectivity). Label 0 is empty.
        var next: Int32 = 1
        var y = 0
        while y < height {
            let row = pixels + y * bytesPerRow
            let line = labels + y * width
            var x = 0
            while x < width {
                if row[x] >= threshold {
                    let left: Int32 = x > 0 ? line[x - 1] : 0
                    let up: Int32 = y > 0 ? line[x - width] : 0
                    if left == 0, up == 0 {
                        parent[Int(next)] = next
                        line[x] = next
                        next += 1
                    } else if left != 0, up != 0 {
                        let a = find(left), b = find(up)
                        line[x] = a
                        if a != b { parent[Int(b)] = a }
                    } else {
                        line[x] = left != 0 ? left : up
                    }
                }
                x += 1
            }
            y += 1
        }
        guard next > 1 else {
            previous = nil
            return
        }

        // Flatten, then one pass for area, box and centroid per blob.
        var l: Int32 = 1
        while l < next {
            parent[Int(l)] = find(l)
            area[Int(l)] = 0
            minX[Int(l)] = Int32.max; maxX[Int(l)] = -1
            minY[Int(l)] = Int32.max; maxY[Int(l)] = -1
            sumX[Int(l)] = 0; sumY[Int(l)] = 0
            l += 1
        }
        y = 0
        while y < height {
            let line = labels + y * width
            var x = 0
            while x < width {
                let label = line[x]
                if label != 0 {
                    let r = Int(parent[Int(label)])
                    area[r] += 1
                    if Int32(x) < minX[r] { minX[r] = Int32(x) }
                    if Int32(x) > maxX[r] { maxX[r] = Int32(x) }
                    if Int32(y) < minY[r] { minY[r] = Int32(y) }
                    if Int32(y) > maxY[r] { maxY[r] = Int32(y) }
                    sumX[r] += x
                    sumY[r] += y
                }
                x += 1
            }
            y += 1
        }

        // Choose the main blob.
        let minArea = max(4, Int32(Double(count) * minAreaFraction))
        let w = Double(width), h = Double(height)
        var best = -1, bestScore = 0.0
        var nearest = -1, nearestScore = 0.0, nearestDistance = Double.greatestFiniteMagnitude
        l = 1
        while l < next {
            let r = Int(l)
            if parent[r] == l, area[r] >= minArea {
                let cx = (Double(sumX[r]) / Double(area[r]) + 0.5) / w
                let cy = (Double(sumY[r]) / Double(area[r]) + 0.5) / h
                let offCentre = (((cx - 0.5) * (cx - 0.5) + (cy - 0.5) * (cy - 0.5)).squareRoot()) / 0.7071
                let score = Double(area[r]) * (1.5 - min(1, offCentre))
                if score > bestScore { best = r; bestScore = score }
                if let p = previous {
                    let d = ((cx - p.x) * (cx - p.x) + (cy - p.y) * (cy - p.y)).squareRoot()
                    if d < nearestDistance { nearest = r; nearestScore = score; nearestDistance = d }
                }
            }
            l += 1
        }
        guard best >= 0 else {
            // Only specks: nobody to keep. Leave the mask as today.
            previous = nil
            return
        }
        // Hysteresis: stay on the blob nearest last frame's unless another
        // is much bigger. "Nearest" only counts if it is still close.
        if nearest >= 0, nearest != best, nearestDistance < 0.25,
           bestScore < nearestScore * switchRatio {
            best = nearest
        }
        previous = ((Double(sumX[best]) / Double(area[best]) + 0.5) / w,
                    (Double(sumY[best]) / Double(area[best]) + 0.5) / h)

        // Keep the main blob and any blob that meets its expanded box.
        let bw = Double(maxX[best] - minX[best] + 1), bh = Double(maxY[best] - minY[best] + 1)
        let padX = Int32(bw * margin) + 2, padY = Int32(bh * margin) + 2
        let boxMinX = minX[best] - padX, boxMaxX = maxX[best] + padX
        let boxMinY = minY[best] - padY, boxMaxY = maxY[best] + padY
        var dropped = false
        l = 1
        while l < next {
            let r = Int(l)
            if parent[r] == l {
                let keeps = r == best || (area[r] >= minArea
                    && maxX[r] >= boxMinX && minX[r] <= boxMaxX
                    && maxY[r] >= boxMinY && minY[r] <= boxMaxY)
                keep[r] = keeps ? 1 : 0
                if !keeps { dropped = true }
            }
            l += 1
        }
        guard dropped else { return }

        // Erase dropped blobs and the soft halo around them (pixels under the
        // threshold that no blob owns, inside a dropped blob's padded box).
        // Halos around kept blobs stay, so the edge feathering is untouched.
        l = 1
        while l < next {
            let r = Int(l)
            if parent[r] == l, keep[r] == 0 {
                let y0 = max(0, Int(minY[r]) - 2), y1 = min(height - 1, Int(maxY[r]) + 2)
                let x0 = max(0, Int(minX[r]) - 2), x1 = min(width - 1, Int(maxX[r]) + 2)
                var yy = y0
                while yy <= y1 {
                    let row = pixels + yy * bytesPerRow
                    let line = labels + yy * width
                    var xx = x0
                    while xx <= x1 {
                        let label = line[xx]
                        if label == 0 {
                            // Halo, unless it sits inside the kept box.
                            if Int32(xx) < boxMinX || Int32(xx) > boxMaxX
                                || Int32(yy) < boxMinY || Int32(yy) > boxMaxY { row[xx] = 0 }
                        } else if keep[Int(parent[Int(label)])] == 0 {
                            row[xx] = 0
                        }
                        xx += 1
                    }
                    yy += 1
                }
            }
            l += 1
        }
    }

    // MARK: Storage

    private func find(_ start: Int32) -> Int32 {
        var x = start
        while parent[Int(x)] != x {
            parent[Int(x)] = parent[Int(parent[Int(x)])]
            x = parent[Int(x)]
        }
        return x
    }

    private func reserve(_ n: Int) {
        guard n > capacity else { return }
        free()
        capacity = n
        labels = .allocate(capacity: n)
        let n = n / 2 + 2   // 4-connected blobs: at most half the pixels, plus one
        parent = .allocate(capacity: n)
        area = .allocate(capacity: n)
        minX = .allocate(capacity: n); maxX = .allocate(capacity: n)
        minY = .allocate(capacity: n); maxY = .allocate(capacity: n)
        sumX = .allocate(capacity: n); sumY = .allocate(capacity: n)
        keep = .allocate(capacity: n)
    }

    private func free() {
        parent.deallocate(); area.deallocate()
        minX.deallocate(); maxX.deallocate(); minY.deallocate(); maxY.deallocate()
        sumX.deallocate(); sumY.deallocate(); keep.deallocate()
        labels.deallocate()
        capacity = 0
    }
}
