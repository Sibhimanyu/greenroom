//
//  StageLayout+OBS.swift
//  Greenroom
//
//  Bridge from the OBS-era layout type. Deleted with GreenroomScene.
//
import Foundation

extension StageLayout {
    init(_ bubble: GreenroomScene.BubbleLayout) {
        self.init(widthFraction: bubble.widthFraction, rightInset: bubble.rightInset,
                  bottomInset: bubble.bottomInset,
                  cutoutHeightFraction: bubble.cutoutHeightFraction,
                  cutoutRightInset: bubble.cutoutRightInset, shape: bubble.shape,
                  showsContent: bubble.showsContent, showsCamera: bubble.showsCamera)
    }
}
