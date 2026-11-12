//
//  WorkspaceLayout.swift
//  Greenroom
//
//  The fixed main-pane + side-column arrangement the layout creator replaced.
//  Kept as a decode-only legacy shape: a settings file exported before the
//  creator carries one under "workspaceLayout", and an import reads it into
//  "Your previous layout". Nothing lays windows out from it any more, and
//  nothing saves it (LegacyLayoutSettings reads the old stored JSON itself).
//
import Foundation

struct WorkspaceLayout: Codable, Equatable {

    var mainFraction: Double
    var mainOnLeft: Bool
    var sideShowsZoomTile: Bool
    var sideShowsChat: Bool
    var zoomSlotRatio: Double
    var arrangeWindowsOnStart: Bool

    init(mainFraction: Double = 0.5,
         mainOnLeft: Bool = true,
         sideShowsZoomTile: Bool = true,
         sideShowsChat: Bool = true,
         zoomSlotRatio: Double = 0.4,
         arrangeWindowsOnStart: Bool = false) {
        self.mainFraction = mainFraction
        self.mainOnLeft = mainOnLeft
        self.sideShowsZoomTile = sideShowsZoomTile
        self.sideShowsChat = sideShowsChat
        self.zoomSlotRatio = zoomSlotRatio
        self.arrangeWindowsOnStart = arrangeWindowsOnStart
    }

    // MARK: Codable - every field optional on decode, so a partial or
    // older exported-settings file imports cleanly.

    private enum CodingKeys: String, CodingKey {
        case mainFraction, mainOnLeft, sideShowsZoomTile, sideShowsChat, zoomSlotRatio
        case arrangeWindowsOnStart
    }

    /// The pre-continuous era stored a three-case enum under "split" -
    /// decoded here so existing setups keep their width.
    private enum LegacyKeys: String, CodingKey { case split }
    private enum LegacySplit: String, Codable {
        case half, twoThirds, threeQuarters
        var fraction: Double {
            switch self {
            case .half: return 0.5
            case .twoThirds: return 2.0 / 3.0
            case .threeQuarters: return 0.75
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let legacyFraction = (try? legacy?.decodeIfPresent(LegacySplit.self, forKey: .split))??.fraction
        self.init(
            mainFraction: (try? container.decodeIfPresent(Double.self, forKey: .mainFraction)) ?? legacyFraction ?? 0.5,
            mainOnLeft: (try? container.decodeIfPresent(Bool.self, forKey: .mainOnLeft)) ?? true,
            sideShowsZoomTile: (try? container.decodeIfPresent(Bool.self, forKey: .sideShowsZoomTile)) ?? true,
            sideShowsChat: (try? container.decodeIfPresent(Bool.self, forKey: .sideShowsChat)) ?? true,
            zoomSlotRatio: (try? container.decodeIfPresent(Double.self, forKey: .zoomSlotRatio)) ?? 0.4,
            arrangeWindowsOnStart: (try? container.decodeIfPresent(Bool.self, forKey: .arrangeWindowsOnStart)) ?? false
        )
    }

    /// The pre-generalization era stored ChromeWindowManager.Layout's
    /// rawValue under "chromeLayout" - map those three cases so an old
    /// export still imports.
    init?(legacyChromeLayout raw: String) {
        switch raw {
        case "leftHalf": self.init()
        case "rightHalf": self.init(mainOnLeft: false)
        case "leftThreeQuarters": self.init(mainFraction: 0.75)
        default: return nil
        }
    }
}
