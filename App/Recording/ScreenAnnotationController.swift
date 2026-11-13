//
//  ScreenAnnotationController.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/ScreenAnnotation.swift:
//  `ScreenAnnotationController`, `AnnotationCanvasPanel`, `AnnotationCanvasView`, `AnnotationChromeView`).
//  Phase 5 of the Recorditor port, see docs/recorditor-integration/drawing-port-log.md.
//
//  The user draws on a transparent window laid over their real screen. That
//  window, the toolbar and the edit handles are all Greenroom windows, so they
//  are never captured (display share excludes the app; app and window shares
//  include only the shared app). What reaches the picture is a second copy of
//  the marks, drawn to an image by `AnnotationMarksRenderer` and handed to the
//  Stage through `onOverlay`, redrawn only when a mark changes.
//
import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenAnnotationController {
    let model = ScreenAnnotationModel()
    private var canvasPanel: AnnotationCanvasPanel?
    private var toolbarPanel: NSPanel?
    private var canvasView: AnnotationCanvasView?
    /// The hovered mark's box, x and resize handle: a window of its own.
    private var chromePanel: NSPanel?
    private var chromeView: AnnotationChromeView?
    private var screen: NSScreen?
    private var observation: AnyCancellable?
    private var pointerMonitors: [Any] = []
    private var pollTimer: Timer?
    private var overlayPending = false
    private var followsWindow = false
    private var lastFrame: CGRect?

    /// Done (Esc, the Done button, the Draw button again).
    var onClose: (() -> Void)?
    /// W, or the toolbar's Whiteboard button.
    var onWhiteboard: (() -> Void)?
    /// A fresh picture of the marks for the Stage, or nil when there are none.
    var onOverlay: ((StageMarksOverlay?) -> Void)?
    /// What the live capture shows right now, in global points: the display
    /// or the followed window.
    var capturedFrame: () -> CGRect? = { nil }

    var isActive: Bool { canvasPanel?.isVisible ?? false }

    // MARK: Begin and end

    /// `followsWindow`: a window share. Drawing is then confined to the
    /// captured window, and the marks move with it.
    func begin(on screen: NSScreen, followsWindow: Bool) {
        if canvasPanel == nil { build() }
        guard let canvasPanel, let toolbarPanel, let canvasView else { return }
        self.screen = screen
        self.followsWindow = followsWindow
        model.drawableArea = nil
        lastFrame = nil
        canvasPanel.setFrame(screen.frame, display: true)
        canvasView.origin = Self.cgOrigin(of: screen)
        canvasPanel.orderFrontRegardless()
        chromePanel?.setFrame(screen.frame, display: true)
        chromePanel?.orderFrontRegardless()
        place(toolbarPanel, on: screen)
        toolbarPanel.orderFrontRegardless()
        syncCapturedFrame()
        applyTool()
        canvasPanel.makeKey()
        canvasPanel.makeFirstResponder(canvasView)
        canvasView.needsDisplay = true
        startPolling()
    }

    /// Puts the canvas and toolbar away but keeps the marks: the whiteboard
    /// is up, and the marks come back with `begin` when it goes.
    func suspend() {
        pollTimer?.invalidate(); pollTimer = nil
        removePointerMonitors()
        canvasPanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        chromePanel?.orderOut(nil)
        chromeView?.box = nil
    }

    /// Done: the canvas and toolbar go, the marks are cleared and the Stage
    /// stops drawing them.
    func end() {
        pollTimer?.invalidate(); pollTimer = nil
        removePointerMonitors()
        canvasPanel?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        chromePanel?.orderOut(nil)
        chromeView?.box = nil
        model.drawableArea = nil
        model.reset()
        lastFrame = nil
        canvasView?.needsDisplay = true
        onOverlay?(nil)
    }

    // MARK: Following the capture

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.pollTimer === timer else { return }
                self.syncCapturedFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// The captured area moved: a window share carries the marks with the
    /// window and keeps drawing inside it; a display share follows the
    /// display (the recording switched screens).
    private func syncCapturedFrame() {
        guard isActive, let frame = capturedFrame(), frame.width > 1, frame.height > 1 else { return }
        defer { lastFrame = frame }
        if followsWindow {
            if let last = lastFrame, last.origin != frame.origin {
                model.translateAll(by: CGSize(width: frame.minX - last.minX, height: frame.minY - last.minY))
            }
            if model.drawableArea != frame {
                model.drawableArea = frame
                canvasView?.needsDisplay = true
            }
        } else if let target = Self.screen(coveringCG: frame), target != screen {
            move(to: target)
        }
        if let last = lastFrame, last.size != frame.size { scheduleOverlay() }
    }

    private func move(to screen: NSScreen) {
        guard let canvasPanel, let toolbarPanel, let canvasView else { return }
        self.screen = screen
        canvasPanel.setFrame(screen.frame, display: true)
        canvasView.origin = Self.cgOrigin(of: screen)
        chromePanel?.setFrame(screen.frame, display: true)
        place(toolbarPanel, on: screen)
        canvasView.needsDisplay = true
    }

    // MARK: Geometry between Cocoa and CoreGraphics

    /// The primary display's height: where CoreGraphics' y = 0 sits in Cocoa.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    /// The screen's top-left corner in global CoreGraphics points.
    static func cgOrigin(of screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    }

    static func screen(coveringCG frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            let origin = cgOrigin(of: screen)
            return CGRect(origin: origin, size: screen.frame.size).insetBy(dx: -1, dy: -1).contains(frame.insetBy(dx: 1, dy: 1))
        }
    }

    // MARK: Overlay for the Stage

    /// Called whenever a mark changes. Coalesced to ~30 Hz so a stroke under
    /// way costs one image per frame at most, and nothing when idle.
    func scheduleOverlay() {
        guard isActive, !overlayPending else { return }
        overlayPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.overlayPending = false
            self.publishOverlay()
        }
    }

    private func publishOverlay() {
        guard isActive else { return }
        let frame = capturedFrame() ?? lastFrame
            ?? screen.map { CGRect(origin: Self.cgOrigin(of: $0), size: $0.frame.size) }
        guard let frame else { onOverlay?(nil); return }
        let all = model.marks + (model.inProgress.map { [$0] } ?? [])
        onOverlay?(AnnotationMarksRenderer.image(of: all, over: frame, clip: followsWindow ? frame : nil))
    }

    // MARK: Pointer mode

    private func removePointerMonitors() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
    }

    /// Pointer mode: take the mouse only while it's over a mark.
    private func trackPointer() {
        guard let canvasPanel, let canvasView, model.tool == .pointer, isActive,
              !canvasView.isEditing else { return }
        let overMark = canvasView.hover(atScreen: NSEvent.mouseLocation)
        if canvasPanel.ignoresMouseEvents == overMark { canvasPanel.ignoresMouseEvents = !overMark }
    }

    /// Pointer passes clicks through to the apps below (the marks stay);
    /// the drawing tools take the mouse.
    private func applyTool() {
        guard let canvasPanel else { return }
        let drawing = model.tool != .pointer
        if drawing || !isActive {
            removePointerMonitors()
        } else if pointerMonitors.isEmpty {
            let track: (NSEvent) -> Void = { [weak self] _ in self?.trackPointer() }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { event in
                MainActor.assumeIsolated { track(event) }
            }) { pointerMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
                track(event)
                return event
            }) { pointerMonitors.append(local) }
        }
        if drawing { canvasPanel.ignoresMouseEvents = false } else { trackPointer() }
        if model.tool == .eraser { chromeView?.box = nil }
        if drawing, !canvasPanel.isKeyWindow { canvasPanel.makeKey() }
        if let canvasView { canvasPanel.invalidateCursorRects(for: canvasView) }
        canvasView?.needsDisplay = true
    }

    private func place(_ toolbar: NSPanel, on screen: NSScreen) {
        let size = toolbar.contentView?.fittingSize ?? NSSize(width: 560, height: 84)
        let visible = screen.visibleFrame
        toolbar.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(),
                                y: visible.maxY - size.height - 14,
                                width: size.width, height: size.height), display: true)
    }

    // MARK: Building the windows

    private func build() {
        let canvas = AnnotationCanvasPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        canvas.isReleasedWhenClosed = false
        // Above ordinary windows (slides, browsers), below the camera bubble
        // and Greenroom's floating controls.
        canvas.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.hasShadow = false
        canvas.hidesOnDeactivate = false
        canvas.becomesKeyOnlyIfNeeded = false
        canvas.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        canvas.sharingType = .none
        let view = AnnotationCanvasView(model: model)
        view.onDone = { [weak self] in self?.onClose?() }
        view.onWhiteboard = { [weak self] in self?.onWhiteboard?() }
        view.onChrome = { [weak self] box in self?.chromeView?.box = box }
        // Drawing begun outside the shared window: said next to the pointer
        // and under the toolbar.
        view.onRefused = { [weak self] in
            guard let self else { return }
            self.chromeView?.show(note: ScreenAnnotationModel.outsideWindowNote, at: NSEvent.mouseLocation)
            self.model.say(ScreenAnnotationModel.outsideWindowNote)
        }
        canvas.contentView = view
        canvasView = view
        canvasPanel = canvas

        let toolbar = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 84),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        toolbar.isReleasedWhenClosed = false
        toolbar.level = .statusBar
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.hasShadow = false
        toolbar.isMovableByWindowBackground = true
        toolbar.hidesOnDeactivate = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.sharingType = .none
        let hosting = FirstMouseHost(rootView: AnnotationToolbarView(
            model: model,
            onWhiteboard: { [weak self] in self?.onWhiteboard?() },
            onDone: { [weak self] in self?.onClose?() }).tint(Brand.green))
        toolbar.contentView = hosting
        toolbar.setContentSize(hosting.fittingSize)
        toolbarPanel = toolbar

        let chrome = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        chrome.isReleasedWhenClosed = false
        chrome.level = .floating
        chrome.isOpaque = false
        chrome.backgroundColor = .clear
        chrome.hasShadow = false
        chrome.ignoresMouseEvents = true
        chrome.hidesOnDeactivate = false
        chrome.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        chrome.sharingType = .none
        let chromeContent = AnnotationChromeView()
        chrome.contentView = chromeContent
        chromeView = chromeContent
        chromePanel = chrome

        model.onMarksChanged = { [weak self] in
            self?.canvasView?.needsDisplay = true
            self?.scheduleOverlay()
        }
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyTool()
                self?.canvasView?.needsDisplay = true
            }
        }
    }

    private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

final class AnnotationCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The canvas

/// Draws the marks and turns drags into new ones. Marks live in global
/// points; `origin` is where this view's top-left sits in that space.
final class AnnotationCanvasView: NSView {
    private let model: ScreenAnnotationModel
    /// The stroke being drawn right now is `model.inProgress`.
    var hasStroke: Bool { MainActor.assumeIsolated { model.inProgress != nil } }
    /// Global CG point of this view's top-left corner.
    var origin: CGPoint = .zero { didSet { needsDisplay = true } }
    /// A stroke was begun outside the shared window.
    var onRefused: (() -> Void)?
    var onDone: (() -> Void)?
    var onWhiteboard: (() -> Void)?
    /// The hovered mark's box in screen coordinates (nil = none), drawn by
    /// the chrome window.
    var onChrome: ((NSRect?) -> Void)?

    private enum Edit { case move(from: CGPoint, original: ScreenAnnotationModel.Mark)
                        case resize(original: ScreenAnnotationModel.Mark, box: CGRect) }
    private var hovered: Int?
    private var edit: (index: Int, kind: Edit)?
    private static let boxPadding: CGFloat = 8
    private static let buttonRadius: CGFloat = 11

    init(model: ScreenAnnotationModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // MARK: space

    /// A point in this view to a global point, and back.
    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
    private func globalPoint(of event: NSEvent) -> CGPoint { global(convert(event.locationInWindow, from: nil)) }

    // MARK: editing marks

    private var marks: [ScreenAnnotationModel.Mark] { MainActor.assumeIsolated { model.marks } }
    private var tool: ScreenAnnotationModel.Tool { MainActor.assumeIsolated { model.tool } }

    private func box(of index: Int) -> CGRect {
        marks[index].bounds.insetBy(dx: -Self.boxPadding, dy: -Self.boxPadding)
    }
    private func deleteCenter(of box: CGRect) -> CGPoint { CGPoint(x: box.maxX, y: box.minY) }
    private func handleCenter(of box: CGRect) -> CGPoint { CGPoint(x: box.maxX, y: box.maxY) }
    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= Self.buttonRadius + 3 }

    /// What's under the pointer: the hovered mark keeps its whole box (so
    /// the x and the handle can be reached), others need a hit on the line.
    private func markAt(_ point: CGPoint) -> Int? {
        if let hovered, marks.indices.contains(hovered) {
            let box = box(of: hovered)
            if box.insetBy(dx: -Self.buttonRadius, dy: -Self.buttonRadius).contains(point) { return hovered }
        }
        return marks.indices.reversed().first { marks[$0].hits(point) }
    }

    private func setHovered(_ index: Int?) {
        hovered = index
        guard let index, marks.indices.contains(index), let window else { onChrome?(nil); return }
        let box = box(of: index)
        let localBox = CGRect(origin: local(box.origin), size: box.size)
        onChrome?(window.convertToScreen(convert(localBox, to: nil)))
    }

    /// Marks can be edited with any tool except the eraser; with the Pointer
    /// the controller hands the canvas the mouse only while it's over one.
    private var canEdit: Bool { tool != .eraser }

    private static let eraserRadius: CGFloat = 14
    private var lastErase: CGPoint?
    private static let eraserCursor: NSCursor = {
        let diameter = eraserRadius * 2
        let image = NSImage(size: NSSize(width: diameter + 2, height: diameter + 2), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor.white.withAlphaComponent(0.35).setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.7).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }()

    /// Erases along the drag, filled in between events so a quick swipe
    /// doesn't skip.
    private func erase(to point: CGPoint) {
        let from = lastErase ?? point
        let distance = hypot(point.x - from.x, point.y - from.y)
        let steps = max(1, Int(distance / (Self.eraserRadius / 2)))
        MainActor.assumeIsolated {
            for index in 1...steps {
                let t = CGFloat(index) / CGFloat(steps)
                model.erase(at: CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t),
                            radius: Self.eraserRadius)
            }
        }
        lastErase = point
        needsDisplay = true
    }

    var isEditing: Bool { edit != nil }

    private func cursor(at point: CGPoint, index: Int) {
        let box = box(of: index)
        if near(point, deleteCenter(of: box)) { NSCursor.pointingHand.set() }
        else if near(point, handleCenter(of: box)) { NSCursor.crosshair.set() }
        else { NSCursor.openHand.set() }
    }

    /// Pointer mode, from the controller's mouse monitor: hover the mark
    /// under a screen point (if any) and say whether there is one.
    func hover(atScreen screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let point = global(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        let index = markAt(point)
        if index != hovered { setHovered(index) }
        if let index { cursor(at: point, index: index) }
        return index != nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard canEdit, edit == nil, !hasStroke else { return }
        let point = globalPoint(of: event)
        let index = markAt(point)
        if index != hovered { setHovered(index) }
        if let index { cursor(at: point, index: index) }
    }

    override func mouseExited(with event: NSEvent) {
        if edit == nil { setHovered(nil) }
    }

    /// Clicked on a hovered mark: delete, start resizing, or start moving.
    private func beginEdit(at point: CGPoint) -> Bool {
        guard canEdit, let index = markAt(point) else { return false }
        let box = box(of: index)
        if near(point, deleteCenter(of: box)) {
            MainActor.assumeIsolated { model.remove(at: index) }
            setHovered(nil)
            return true
        }
        if near(point, handleCenter(of: box)) {
            edit = (index, .resize(original: marks[index], box: marks[index].bounds))
        } else {
            edit = (index, .move(from: point, original: marks[index]))
            NSCursor.closedHand.set()
        }
        setHovered(index)
        return true
    }

    private func continueEdit(to point: CGPoint) {
        guard let edit, marks.indices.contains(edit.index) else { return }
        MainActor.assumeIsolated {
            switch edit.kind {
            case let .move(from, original):
                model.replace(at: edit.index,
                              with: original.moved(by: CGSize(width: point.x - from.x, height: point.y - from.y)))
            case let .resize(original, box):
                // The handle sits at the padded box's corner; the mark's own
                // box grows to follow it, top-left fixed.
                let width = max(12, point.x - Self.boxPadding - box.minX)
                let height = max(12, point.y - Self.boxPadding - box.minY)
                model.replace(at: edit.index,
                              with: original.scaled(from: box, to: CGRect(x: box.minX, y: box.minY, width: width, height: height)))
            }
        }
        setHovered(edit.index)
        needsDisplay = true
    }

    override func resetCursorRects() {
        let drawCursor: NSCursor = tool == .eraser ? Self.eraserCursor : .crosshair
        if tool != .pointer { addCursorRect(bounds, cursor: drawCursor) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = globalPoint(of: event)
        if tool == .eraser {
            setHovered(nil)
            lastErase = nil
            erase(to: point)
            return
        }
        if beginEdit(at: point) { needsDisplay = true; return }
        guard tool != .pointer else { return }
        // A window share: only over the window.
        let area = MainActor.assumeIsolated { model.drawableArea }
        if let area, !area.contains(point) {
            onRefused?()
            return
        }
        setHovered(nil)
        MainActor.assumeIsolated {
            model.inProgress = .init(tool: model.tool, color: model.color, points: [point])
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if edit != nil {
            continueEdit(to: globalPoint(of: event))
            return
        }
        if tool == .eraser, lastErase != nil {
            erase(to: globalPoint(of: event))
            return
        }
        guard var mark = MainActor.assumeIsolated({ model.inProgress }) else { return }
        var point = globalPoint(of: event)
        // A stroke stays on the shared window.
        if let area = MainActor.assumeIsolated({ model.drawableArea }) {
            point = CGPoint(x: min(max(point.x, area.minX), area.maxX), y: min(max(point.y, area.minY), area.maxY))
        }
        if mark.tool == .arrow {
            mark.points = [mark.points[0], point]
        } else if let last = mark.points.last, hypot(point.x - last.x, point.y - last.y) >= 1.5 {
            mark.points.append(point)
        }
        MainActor.assumeIsolated { model.inProgress = mark }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if edit != nil {
            edit = nil
            NSCursor.openHand.set()
            return
        }
        if lastErase != nil {
            lastErase = nil
            return
        }
        guard let mark = MainActor.assumeIsolated({ model.inProgress }) else { return }
        MainActor.assumeIsolated { model.inProgress = nil }
        // A click without a drag leaves nothing (an arrow needs a length).
        let start = mark.points[0], end = mark.points.last ?? start
        if mark.points.count > 1, hypot(end.x - start.x, end.y - start.y) > 4 || mark.tool != .arrow {
            MainActor.assumeIsolated { model.add(mark) }
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    /// Keys are local to the canvas, which is the key window while a tool
    /// is picked: V / P / H / A / E pick a tool, W the whiteboard, Cmd-Z
    /// undo, Esc done. No global key monitor.
    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { onDone?(); return }   // Esc
        MainActor.assumeIsolated {
            if event.modifierFlags.contains(.command), key == "z" { model.undo(); return }
            switch key {
            case "v": model.tool = .pointer
            case "p": model.tool = .pen
            case "h": model.tool = .highlighter
            case "a": model.tool = .arrow
            case "e": model.tool = .eraser
            case "w": onWhiteboard?()
            default: super.keyDown(with: event)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let (drawing, area, all) = MainActor.assumeIsolated {
            (model.tool != .pointer, model.drawableArea,
             model.marks + (model.inProgress.map { [$0] } ?? []))
        }
        // The screen dims while a tool is picked, so it is plain that clicks
        // now draw. A window share dims the rest of the screen more (it isn't
        // in the picture) and leaves the window clear.
        if drawing {
            let outside = NSBezierPath(rect: bounds)
            if let area {
                outside.append(NSBezierPath(rect: CGRect(origin: local(area.origin), size: area.size)))
                outside.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.3).setFill()
            } else {
                NSColor.black.withAlphaComponent(0.1).setFill()
            }
            outside.fill()
        }
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        if let area { context.clip(to: area) }
        for mark in all { AnnotationPainter.draw(mark) }
        context.restoreGState()
    }
}

// MARK: - Edit handles

/// The hovered mark's dashed box, red x (delete) and resize handle, drawn
/// over the canvas in a window of its own.
final class AnnotationChromeView: NSView {
    /// In screen coordinates.
    var box: NSRect? { didSet { if box != oldValue { needsDisplay = true } } }
    private var note: (text: String, at: NSPoint)?
    private var noteToken = 0

    func show(note text: String, at point: NSPoint) {
        note = (text, point)
        noteToken += 1
        let token = noteToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.noteToken == token else { return }
            self.note = nil
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawNote()
        guard let box, let window else { return }
        let rect = convert(window.convertFromScreen(box), from: nil)

        let outline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        outline.lineWidth = 1.5
        outline.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        outline.stroke()

        // Resize handle, bottom right (this view is not flipped).
        let handle = NSRect(x: rect.maxX - 7, y: rect.minY - 7, width: 14, height: 14)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: handle).fill()
        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(ovalIn: handle.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()

        // Delete, top right.
        let delete = NSRect(x: rect.maxX - 11, y: rect.maxY - 11, width: 22, height: 22)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor(red: 1, green: 0.29, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(ovalIn: delete).fill()
        NSGraphicsContext.restoreGraphicsState()
        let cross = NSBezierPath()
        let inset = delete.insetBy(dx: 7, dy: 7)
        cross.move(to: CGPoint(x: inset.minX, y: inset.minY)); cross.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
        cross.move(to: CGPoint(x: inset.minX, y: inset.maxY)); cross.line(to: CGPoint(x: inset.maxX, y: inset.minY))
        cross.lineWidth = 2
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }

    private func drawNote() {
        guard let note, let window else { return }
        let text = NSAttributedString(string: note.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        let point = convert(window.convertPoint(fromScreen: note.at), from: nil)
        var rect = NSRect(x: point.x + 14, y: point.y - size.height - 18, width: size.width + 20, height: size.height + 10)
        // Kept on the screen.
        rect.origin.x = min(max(rect.minX, bounds.minX + 6), bounds.maxX - rect.width - 6)
        rect.origin.y = min(max(rect.minY, bounds.minY + 6), bounds.maxY - rect.height - 6)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.85).setFill()
        capsule.fill()
        text.draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 5))
    }
}
