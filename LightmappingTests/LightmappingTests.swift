import simd
import XCTest
@testable import Lightmapping

final class WarpMeshTests: XCTestCase {
    private func assertClose(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testHomographyMapsUnitSquareCornersToQuad() {
        let tl = SIMD2<Float>(0.1, 0.2), tr = SIMD2<Float>(0.8, 0.1), br = SIMD2<Float>(0.9, 0.95), bl = SIMD2<Float>(0.05, 0.7)
        let h = Homography.squareToQuad(tl, tr, br, bl)
        assertClose(h.apply(SIMD2(0, 0)), tl)
        assertClose(h.apply(SIMD2(1, 0)), tr)
        assertClose(h.apply(SIMD2(1, 1)), br)
        assertClose(h.apply(SIMD2(0, 1)), bl)
    }

    func testHomographyInverseRoundTrips() {
        let h = Homography.squareToQuad(SIMD2(0.2, 0.1), SIMD2(0.7, 0.2), SIMD2(0.75, 0.8), SIMD2(0.1, 0.9))
        let uv = SIMD2<Float>(0.3, 0.6)
        assertClose(h.inverse.apply(h.apply(uv)), uv)
    }

    func testPerspectiveKeepsStraightLinesStraight() {
        // Midpoints of a projected line must be collinear with its ends.
        let mesh = WarpMesh.quad(SIMD2(0.1, 0.1), SIMD2(0.9, 0.3), SIMD2(0.1, 0.9), SIMD2(0.9, 0.7))
        let a = mesh.map(SIMD2(0, 0.5)), b = mesh.map(SIMD2(0.5, 0.5)), c = mesh.map(SIMD2(1, 0.5))
        let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        XCTAssertEqual(cross, 0, accuracy: 1e-5)
    }

    func testResampledMeshPreservesShapeAndInterpolatesControlPoints() {
        let mesh = WarpMesh.rect(center: SIMD2(0.5, 0.5), size: SIMD2(0.4, 0.4))
        let dense = mesh.resampled(columns: 4, rows: 4)
        XCTAssertEqual(dense.points.count, 16)
        for uv in [SIMD2<Float>(0, 0), SIMD2(1, 1), SIMD2(0.5, 0.5), SIMD2(1.0 / 3, 2.0 / 3)] {
            assertClose(dense.map(uv), mesh.map(uv), accuracy: 1e-3)
        }
        // Catmull-Rom passes through its control points.
        assertClose(dense.map(SIMD2(1.0 / 3, 0)), dense[1, 0])
    }

    func testTessellationVertexCount() {
        XCTAssertEqual(WarpMesh.rect(center: SIMD2(0.5, 0.5), size: SIMD2(1, 1)).tessellate(subdivisions: 8).count, 8 * 8 * 6)
    }

    func testContainsAndPolygonSimplify() {
        let mesh = WarpMesh.rect(center: SIMD2(0.5, 0.5), size: SIMD2(0.2, 0.2))
        XCTAssertTrue(mesh.contains(SIMD2(0.5, 0.5)))
        XCTAssertFalse(mesh.contains(SIMD2(0.9, 0.9)))
        let line = (0...20).map { SIMD2<Float>(Float($0) / 20, 0.5) }
        XCTAssertEqual(Polygon.simplify(line, tolerance: 0.001).count, 2)
    }
}

final class ModulationTests: XCTestCase {
    func testLFOShapes() {
        XCTAssertEqual(LFO(shape: .sine, rateBeats: 1).value(beat: 0), 0, accuracy: 1e-5)
        XCTAssertEqual(LFO(shape: .sine, rateBeats: 1).value(beat: 0.5), 1, accuracy: 1e-5)
        XCTAssertEqual(LFO(shape: .triangle, rateBeats: 2).value(beat: 1), 1, accuracy: 1e-5)
        XCTAssertEqual(LFO(shape: .saw, rateBeats: 4).value(beat: 1), 0.25, accuracy: 1e-5)
        XCTAssertEqual(LFO(shape: .square, rateBeats: 1).value(beat: 0.25), 1)
        let r = LFO(shape: .random, rateBeats: 1)
        XCTAssertEqual(r.value(beat: 3.1), r.value(beat: 3.9), "random LFO holds within a cycle")
    }

    func testParamModulation() {
        var ctx = ModulationContext()
        ctx.audio.bass = 0.5
        ctx.lfo = [1]
        XCTAssertEqual(Param(1, modulation: Modulation(source: .audioBass, depth: 2)).value(ctx), 2, accuracy: 1e-6)
        // Bipolar sources swing around the base: LFO at 1 -> +depth.
        XCTAssertEqual(Param(1, modulation: Modulation(source: .lfo(0), depth: 0.5)).value(ctx), 1.5, accuracy: 1e-6)
        XCTAssertEqual(Param(0.3).value(ctx), 0.3)
    }

    func testEnvelope() {
        let env = Envelope(trigger: .beat, attack: 0.1, decay: 1)
        XCTAssertEqual(env.value(sinceTrigger: nil), 0)
        XCTAssertEqual(env.value(sinceTrigger: 0.05), 0.5, accuracy: 1e-5)
        XCTAssertEqual(env.value(sinceTrigger: 0.1), 1, accuracy: 1e-5)
        XCTAssertLessThan(env.value(sinceTrigger: 1.1), 0.1)
    }

    func testAutomationInterpolation() {
        let lane = AutomationLane(macroIndex: 0, keyframes: [AutomationKeyframe(time: 0, value: 0), AutomationKeyframe(time: 10, value: 1)])
        XCTAssertEqual(lane.value(at: 5)!, 0.5, accuracy: 1e-6)
        XCTAssertEqual(lane.value(at: 20)!, 1)
        XCTAssertEqual(lane.value(at: -1)!, 0)
    }
}

final class ProjectTests: XCTestCase {
    func testTimelineClipLookup() {
        let a = UUID(), b = UUID()
        let tl = Timeline(clips: [TimelineClip(sceneID: a, start: 0, duration: 5), TimelineClip(sceneID: b, start: 5, duration: 5)])
        XCTAssertEqual(tl.clip(at: 2)?.sceneID, a)
        XCTAssertEqual(tl.clip(at: 5)?.sceneID, b)
        XCTAssertNil(tl.clip(at: 11))
        XCTAssertEqual(tl.duration, 10)
    }

    func testProjectRoundTripsThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(root: dir)
        let project = ProjectBrowserView.demoProject()
        try store.save(project)
        let loaded = try XCTUnwrap(store.listProjects().first)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.surfaces, project.surfaces)
        XCTAssertEqual(loaded.scenes, project.scenes)
        XCTAssertEqual(loaded.timeline, project.timeline)
    }

    func testPresetLibrary() {
        let holiday = PresetLibrary.all.filter { $0.category == .halloween || $0.category == .christmas }
        XCTAssertGreaterThan(holiday.count, 50)
        XCTAssertEqual(Set(PresetLibrary.all.map(\.id)).count, PresetLibrary.all.count, "preset IDs are unique")
        let seed1 = PresetLibrary.all[0].makeLayer().generator.seed
        let seed2 = PresetLibrary.all[0].makeLayer().generator.seed
        XCTAssertEqual(seed1, seed2, "seeds are stable")
    }

    func testExportSizesAreEven() {
        for r in ExportResolution.allCases {
            let s = r.size(aspect: 1.6)
            XCTAssertEqual(s.x % 2, 0)
            XCTAssertEqual(s.y % 2, 0)
        }
        XCTAssertEqual(ExportResolution.uhd4K.size(aspect: 16.0 / 9.0), SIMD2(3840, 2160))
    }
}
