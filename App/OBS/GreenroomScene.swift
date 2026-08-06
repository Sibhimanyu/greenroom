//
//  GreenroomScene.swift
//  Greenroom
//
//  Idempotently builds the OBS scene Greenroom needs - full-screen capture
//  as background, webcam keyed and positioned into a corner bubble - then
//  starts the virtual camera.
//
//  Rather than hardcoding OBS's internal source/filter type names (they
//  differ across OBS versions and platforms - see the README), this asks
//  OBS what's actually installed via GetInputKindList / GetSourceFilterKindList
//  and picks the best match. More robust than guessing strings, and it's
//  what a real automation client should do regardless.
//
import Foundation

enum GreenroomScene {

    static let sceneName = "Greenroom"
    static let screenSourceName = "Greenroom Screen"
    static let webcamSourceName = "Greenroom Webcam"
    static let chromaKeyFilterName = "Greenroom Chroma Key"
    static let shapeMaskFilterName = "Greenroom Shape Mask"

    struct BubbleLayout {
        var widthFraction: Double = 0.24
        var rightInset: Double = 0.045
        var bottomInset: Double = 0.06
        var shape: WebcamShape = .circle
    }

    static func ensureConfigured(client: OBSWebSocketClient, bubble: BubbleLayout = BubbleLayout()) async throws {
        // OBS remembers whether the virtual cam was running when it last
        // quit and auto-resumes it on launch - confirmed by testing, that
        // left an active output blocking SetVideoSettings below ("Video
        // settings cannot be changed while an output is active"). Always
        // start from a clean slate instead of guessing whether it's needed.
        _ = try? await client.request("StopVirtualCam")

        try await ensureScene(client: client)

        let screenKind = try await bestInputKind(client: client, containing: ["screen", "display"])
        let webcamKind = try await bestInputKind(client: client, containing: ["av_capture", "dshow", "v4l2"])
        let chromaKind = try await bestFilterKind(client: client, containing: ["chroma_key"])

        // Resolve the real display/camera identifiers *before* creating the
        // inputs, and bake them in via CreateInput's inputSettings rather
        // than patching them onto an already-running source afterward.
        // Confirmed by a real crash: calling SetInputSettings on a live
        // screen_capture source raced with ScreenCaptureKit's async audio
        // callback and segfaulted OBS entirely (EXC_BAD_ACCESS in
        // screen_stream_audio_update). Only ever reconfigure a source that
        // isn't alive yet - remove-and-recreate instead of patch-in-place.
        guard let displayUUID = LocalDeviceResolver.mainDisplayUUID else {
            throw NSError(domain: "Greenroom", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't resolve the main display's UUID."
            ])
        }
        guard let webcamUID = LocalDeviceResolver.physicalCameraUID() else {
            throw NSError(domain: "Greenroom", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "No physical webcam was found (only \u{201C}OBS Virtual Camera\u{201D} itself, or nothing)."
            ])
        }

        try await ensureInput(client: client, name: screenSourceName, kind: screenKind,
                               settings: ["type": 0, "display_uuid": displayUUID],
                               isCorrectlyConfigured: { ($0["display_uuid"] as? String) == displayUUID })
        try await ensureInput(client: client, name: webcamSourceName, kind: webcamKind,
                               settings: ["uid": webcamUID],
                               isCorrectlyConfigured: { ($0["uid"] as? String) == webcamUID })

        try await ensureFilter(client: client, source: webcamSourceName, name: chromaKeyFilterName, kind: chromaKind)
        try await setChromaKey(client: client, enabled: bubble.shape.usesChromaKey)
        try await ensureShapeMask(client: client, shape: bubble.shape)

        // Confirmed by testing: OBS can log "No device selected" for this
        // source at startup even though its saved settings already have the
        // right uid - a startup race where AVFoundation's device list isn't
        // populated yet at the exact moment OBS deserializes the scene
        // collection, and it never retries on its own. Re-applying the same
        // uid here (well after startup, unlike the screen source this one
        // isn't implicated in any crash) forces OBS to re-attempt opening it.
        _ = try? await client.request("SetInputSettings", data: [
            "inputName": webcamSourceName,
            "inputSettings": ["uid": webcamUID],
            "overlay": true
        ])

        // Match the OBS canvas to the screen source's actual native pixel
        // size and stretch the source to exactly fill it (confirmed by
        // testing: a mismatched canvas left the source unscaled at native
        // size, so only its top-left corner was visible within the frame),
        // then position the bubble off that real size rather than a guess.
        let canvas = try await fitCanvasToScreenSource(client: client)
        try await positionBubble(client: client, layout: bubble, canvasWidth: canvas.width, canvasHeight: canvas.height)

        try await client.request("SetCurrentProgramScene", data: ["sceneName": sceneName])
    }

    static func startVirtualCam(client: OBSWebSocketClient, pollAttempts: Int = 6) async throws {
        if let status = try? await client.request("GetVirtualCamStatus"),
           (status["outputActive"] as? Bool) == true {
            return
        }

        // Call StartVirtualCam exactly once - if OBS's camera extension isn't
        // approved yet, OBS shows its own alert every time this is called, so
        // retrying it in a loop just stacks up duplicate dialogs. Instead,
        // poll status afterward: the known macOS quirk (the virtual cam
        // driver not loading synchronously) resolves with polling alone once
        // the extension actually is approved.
        _ = try? await client.request("StartVirtualCam")

        for _ in 1...pollAttempts {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let status = try? await client.request("GetVirtualCamStatus"),
               (status["outputActive"] as? Bool) == true {
                return
            }
        }

        throw NSError(domain: "Greenroom", code: 20, userInfo: [
            NSLocalizedDescriptionKey: "OBS's virtual camera hasn't started. If OBS showed a permission dialog, approve it in System Settings \u{2192} General \u{2192} Login Items & Extensions \u{2192} Camera Extensions, then press Start again."
        ])
    }

    // MARK: - Scene/source/filter discovery + idempotent creation

    private static func ensureScene(client: OBSWebSocketClient) async throws {
        let list = try await client.request("GetSceneList")
        let scenes = (list["scenes"] as? [[String: Any]]) ?? []
        guard !scenes.contains(where: { ($0["sceneName"] as? String) == sceneName }) else { return }
        _ = try await client.request("CreateScene", data: ["sceneName": sceneName])
    }

    private static func bestInputKind(client: OBSWebSocketClient, containing needles: [String]) async throws -> String {
        let response = try await client.request("GetInputKindList")
        let kinds = (response["inputKinds"] as? [String]) ?? []
        for needle in needles {
            if let match = kinds.first(where: { $0.lowercased().contains(needle) }) { return match }
        }
        throw NSError(domain: "Greenroom", code: 21, userInfo: [
            NSLocalizedDescriptionKey: "OBS has no installed source matching \(needles) - is a plugin missing?"
        ])
    }

    private static func bestFilterKind(client: OBSWebSocketClient, containing needles: [String]) async throws -> String {
        let response = try await client.request("GetSourceFilterKindList")
        let kinds = (response["sourceFilterKinds"] as? [String]) ?? []
        for needle in needles {
            if let match = kinds.first(where: { $0.lowercased().contains(needle) }) { return match }
        }
        throw NSError(domain: "Greenroom", code: 22, userInfo: [
            NSLocalizedDescriptionKey: "OBS has no installed filter matching \(needles)."
        ])
    }

    /// Sets the OBS canvas (both base and output resolution, to avoid a
    /// second scaling/distortion pass between them) to the screen source's
    /// real native pixel size, and stretches that source to exactly fill it.
    /// Since destination == source size, "stretch" introduces no distortion.
    private static func fitCanvasToScreenSource(client: OBSWebSocketClient) async throws -> (width: Int, height: Int) {
        let items = try await sceneItems(client: client)
        guard let screenItem = items.first(where: { ($0["sourceName"] as? String) == screenSourceName }),
              let itemId = screenItem["sceneItemId"] as? Int,
              let transform = screenItem["sceneItemTransform"] as? [String: Any],
              let sourceWidth = transform["sourceWidth"] as? Double, sourceWidth > 0,
              let sourceHeight = transform["sourceHeight"] as? Double, sourceHeight > 0 else {
            let video = try await client.request("GetVideoSettings")
            return ((video["baseWidth"] as? Int) ?? 1920, (video["baseHeight"] as? Int) ?? 1080)
        }

        let width = Int(sourceWidth)
        let height = Int(sourceHeight)

        _ = try await client.request("SetVideoSettings", data: [
            "baseWidth": width, "baseHeight": height,
            "outputWidth": width, "outputHeight": height
        ])

        _ = try await client.request("SetSceneItemTransform", data: [
            "sceneName": sceneName,
            "sceneItemId": itemId,
            "sceneItemTransform": [
                "positionX": 0,
                "positionY": 0,
                "boundsType": "OBS_BOUNDS_STRETCH",
                "boundsWidth": width,
                "boundsHeight": height
            ]
        ])

        return (width, height)
    }

    private static func sceneItems(client: OBSWebSocketClient) async throws -> [[String: Any]] {
        let list = try await client.request("GetSceneItemList", data: ["sceneName": sceneName])
        return (list["sceneItems"] as? [[String: Any]]) ?? []
    }

    /// Creates `name` with `settings` baked in if it doesn't exist yet. If it
    /// already exists but `isCorrectlyConfigured` says its current settings
    /// are wrong (e.g. left over from before this app resolved a real
    /// display/camera), removes and recreates it from scratch rather than
    /// patching a potentially-live source in place - see the crash note in
    /// `ensureConfigured` for why that distinction matters.
    private static func ensureInput(
        client: OBSWebSocketClient, name: String, kind: String, settings: [String: Any],
        isCorrectlyConfigured: ([String: Any]) -> Bool
    ) async throws {
        let items = try await sceneItems(client: client)
        if items.contains(where: { ($0["sourceName"] as? String) == name }) {
            let current = try await client.request("GetInputSettings", data: ["inputName": name])
            if isCorrectlyConfigured((current["inputSettings"] as? [String: Any]) ?? [:]) {
                return
            }
            _ = try? await client.request("RemoveInput", data: ["inputName": name])
        }
        _ = try await client.request("CreateInput", data: [
            "sceneName": sceneName,
            "inputName": name,
            "inputKind": kind,
            "inputSettings": settings
        ])
    }

    /// Turns the chroma key on for Cutout mode (green-screen removal, so
    /// the person floats over the shared screen with no background) and
    /// off for the bubble shapes, where the webcam's real background is
    /// part of the look. The filter itself always exists; only its enabled
    /// state and settings change - cheaper than creating/removing it, and
    /// it keeps any manual tweaks the user makes in OBS.
    ///
    /// Settings match OBS's own chroma-key defaults for green, which its
    /// bundled shader is tuned for; they're set explicitly rather than
    /// relying on defaults so a previous session's fiddling can't leave
    /// the key mis-tuned.
    private static func setChromaKey(client: OBSWebSocketClient, enabled: Bool) async throws {
        if enabled {
            _ = try? await client.request("SetSourceFilterSettings", data: [
                "sourceName": webcamSourceName,
                "filterName": chromaKeyFilterName,
                "filterSettings": [
                    "key_color_type": "green",
                    "similarity": 400,
                    "smoothness": 80,
                    "spill": 100,
                    "opacity": 1.0
                ]
            ])
        }
        _ = try? await client.request("SetSourceFilterEnabled", data: [
            "sourceName": webcamSourceName,
            "filterName": chromaKeyFilterName,
            "filterEnabled": enabled
        ])
    }

    private static func ensureFilter(client: OBSWebSocketClient, source: String, name: String, kind: String) async throws {
        let list = try await client.request("GetSourceFilterList", data: ["sourceName": source])
        let filters = (list["filters"] as? [[String: Any]]) ?? []
        guard !filters.contains(where: { ($0["filterName"] as? String) == name }) else { return }
        _ = try await client.request("CreateSourceFilter", data: [
            "sourceName": source,
            "filterName": name,
            "filterKind": kind
        ])
    }

    /// Adds/updates/removes the shape-mask filter to match the chosen
    /// WebcamShape. Square needs no filter at all (the rectangular bounding
    /// box from `positionBubble` already does the job); circle and rounded
    /// rectangle apply OBS's built-in Image Mask/Blend filter
    /// (filterKind "mask_filter_v2") in alpha-mask mode against a generated
    /// PNG - confirmed against OBS's own bundled mask_alpha_filter.effect
    /// shader rather than guessed.
    private static func ensureShapeMask(client: OBSWebSocketClient, shape: WebcamShape) async throws {
        let list = try await client.request("GetSourceFilterList", data: ["sourceName": webcamSourceName])
        let filters = (list["filters"] as? [[String: Any]]) ?? []
        let exists = filters.contains { ($0["filterName"] as? String) == shapeMaskFilterName }

        guard let maskURL = MaskImageGenerator.maskImageURL(for: shape) else {
            if exists {
                _ = try? await client.request("RemoveSourceFilter", data: [
                    "sourceName": webcamSourceName, "filterName": shapeMaskFilterName
                ])
            }
            return
        }

        let settings: [String: Any] = ["type": "mask_alpha_filter.effect", "image_path": maskURL.path]
        if exists {
            _ = try await client.request("SetSourceFilterSettings", data: [
                "sourceName": webcamSourceName, "filterName": shapeMaskFilterName,
                "filterSettings": settings, "overlay": false
            ])
        } else {
            _ = try await client.request("CreateSourceFilter", data: [
                "sourceName": webcamSourceName, "filterName": shapeMaskFilterName,
                "filterKind": "mask_filter_v2", "filterSettings": settings
            ])
        }
    }

    private static func positionBubble(client: OBSWebSocketClient, layout: BubbleLayout, canvasWidth: Int, canvasHeight: Int) async throws {
        let items = try await sceneItems(client: client)
        guard let item = items.first(where: { ($0["sourceName"] as? String) == webcamSourceName }),
              let itemId = item["sceneItemId"] as? Int else { return }

        let width = Double(canvasWidth)
        let height = Double(canvasHeight)
        let diameter = width * layout.widthFraction
        let x = width - width * layout.rightInset - diameter
        let y = height - height * layout.bottomInset - diameter

        _ = try await client.request("SetSceneItemTransform", data: [
            "sceneName": sceneName,
            "sceneItemId": itemId,
            "sceneItemTransform": [
                "positionX": x,
                "positionY": y,
                "boundsType": "OBS_BOUNDS_SCALE_INNER",
                "boundsWidth": diameter,
                "boundsHeight": diameter
            ]
        ])
    }
}
