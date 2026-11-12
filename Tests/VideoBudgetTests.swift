import XCTest

/// Who gets which resolution against Zoom's budget: 2 x 720p, 4 x 360p, 17 x 180p, 34 x 90p.
final class VideoBudgetTests: XCTestCase {

    private func req(_ key: String, _ priority: Int, _ wanted: VideoTier, _ floor: VideoTier,
                     current: VideoTier? = nil) -> VideoRequest {
        VideoRequest(key: key, priority: priority, wanted: wanted, floor: floor, current: current)
    }

    func testQuotas() {
        XCTAssertEqual(VideoTier.p720.quota, 2)
        XCTAssertEqual(VideoTier.p360.quota, 4)
        XCTAssertEqual(VideoTier.p180.quota, 17)
        XCTAssertEqual(VideoTier.p90.quota, 34)
    }

    func testPriorityDecidesWhoGetsTheLast720() {
        let result = VideoBudget.allocate([
            req("gallery", 50, .p180, .p90),
            req("speaker", 10, .p720, .p360),
            req("spotlight", 11, .p720, .p360),
            req("strip.stage", 20, .p720, .p360),
        ])
        XCTAssertEqual(result["speaker"], .some(.p720))
        XCTAssertEqual(result["spotlight"], .some(.p720))
        XCTAssertEqual(result["strip.stage"], .some(.p360), "the third 720p falls to 360p")
        XCTAssertEqual(result["gallery"], .some(.p180))
    }

    func testMeetingWindowStreamsAreTakenFirst() {
        var external = VideoUsage()
        external.take(.p720)            // the meeting window's stage
        let result = VideoBudget.allocate([req("a", 10, .p720, .p360), req("b", 11, .p720, .p360)], external: external)
        XCTAssertEqual(result["a"], .some(.p720))
        XCTAssertEqual(result["b"], .some(.p360))
    }

    func testMultiSpeakerThreeAt360AndTheFourthSpillsDown() {
        let multi = (0..<3).map { req("m\($0)", 30, .p360, .p180) }
        var all = multi
        all.append(req("extra", 40, .p360, .p180))
        all.append(req("extra2", 41, .p360, .p180))
        let r = VideoBudget.allocate(all)
        for key in ["m0", "m1", "m2", "extra"] { XCTAssertEqual(r[key], .some(.p360), key) }
        XCTAssertEqual(r["extra2"], .some(.p180), "four 360p streams are the limit")
    }

    func testNothingLeftIsNilNotACrash() {
        var external = VideoUsage()
        for _ in 0..<34 { external.take(.p90) }
        for _ in 0..<17 { external.take(.p180) }
        let r = VideoBudget.allocate([req("g", 50, .p180, .p90)], external: external)
        XCTAssertNotNil(r["g"], "the key is answered")
        XCTAssertNil(r["g"]!, "and the answer is no stream")
    }

    func testARunningStreamKeepsItsTierWhenAHigherPriorityOpensLater() {
        // The gallery already holds a 720p-free budget; Active speaker opens afterwards.
        let r = VideoBudget.allocate([
            req("speaker", 10, .p720, .p360),
            req("held1", 60, .p720, .p360, current: .p720),
            req("held2", 61, .p720, .p360, current: .p720),
        ])
        XCTAssertEqual(r["held1"], .some(.p720))
        XCTAssertEqual(r["held2"], .some(.p720))
        XCTAssertEqual(r["speaker"], .some(.p360), "what already runs is not reshuffled")
    }

    func testAHeldTierOutsideItsRangeIsRenegotiated() {
        let r = VideoBudget.allocate([req("a", 10, .p360, .p180, current: .p720)])
        XCTAssertEqual(r["a"], .some(.p360))
    }

    func testGalleryPageSizeIsTheFree180pStreamsCappedAt16() {
        XCTAssertEqual(VideoBudget.galleryPageSize(used: VideoUsage()), 16)
        var used = VideoUsage()
        for _ in 0..<10 { used.take(.p180) }
        XCTAssertEqual(VideoBudget.galleryPageSize(used: used), 7)
        for _ in 0..<7 { used.take(.p180) }
        XCTAssertEqual(VideoBudget.galleryPageSize(used: used), 1, "never fewer than one tile")
    }

    func testGalleryTilesUnder200ptAskFor90p() {
        XCTAssertEqual(VideoBudget.galleryTier(tileHeight: 199), .p90)
        XCTAssertEqual(VideoBudget.galleryTier(tileHeight: 200), .p180)
    }

    func testTheSameOrderGivesTheSameAnswer() {
        let requests = [req("a", 10, .p720, .p360), req("b", 20, .p720, .p360), req("c", 20, .p720, .p360)]
        XCTAssertEqual(VideoBudget.allocate(requests), VideoBudget.allocate(requests))
        XCTAssertEqual(VideoBudget.allocate(requests)["b"], .some(.p720), "ties go in the order asked")
        XCTAssertEqual(VideoBudget.allocate(requests)["c"], .some(.p360))
    }
}
