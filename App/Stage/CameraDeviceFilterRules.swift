//
//  CameraDeviceFilterRules.swift
//  Greenroom
//
//  Which attached cameras the owner may pick as their camera device (R49.12, owner, 2026-11-27).
//  Zoom installs a virtual camera ("zoom_virtual_device"); picking it would feed Zoom its own picture.
//  Greenroom's own outputs are never a source either. One pure rule, used by
//  `LocalDeviceResolver.availableCameras()`, which Home, the Devices tab and the bar's camera menu share.
//  Foundation only.
//
import Foundation

enum CameraDeviceFilterRules {
    /// False for Zoom's virtual camera (and anything Zoom installs) and for Greenroom's own outputs.
    static func isListable(uniqueID: String, modelID: String, name: String) -> Bool {
        let id = uniqueID.lowercased(), model = modelID.lowercased(), label = name.lowercased()
        if id.contains("zoom") || model.contains("zoom") { return false }
        if label.hasPrefix("zoom ") || label.hasPrefix("zoom\u{2019}") || label.contains("zoomvirtual") { return false }
        if label.hasPrefix("greenroom") || id.contains("greenroom") || model.contains("greenroom") { return false }
        return true
    }
}
