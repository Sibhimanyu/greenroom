//
//  RoomScreenInspector.swift
//  Greenroom
//
//  The Room screen piece's rows in the layout builder's inspector, under the
//  shared header (R35): one toggle, "Show my camera" (R47).
//
import SwiftUI

struct RoomScreenInspectorRows: View {
    @Binding var showsMyCamera: Bool

    var body: some View {
        HStack {
            Toggle(RoomScreenRules.showMyCameraLabel, isOn: $showsMyCamera)
                .help(RoomScreenRules.showMyCameraTip)
            Spacer()
        }
    }
}
