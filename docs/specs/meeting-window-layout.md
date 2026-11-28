# Meeting window layout: the window's sums as pure rules

Code: `App/UI/MeetingWindow/MeetingWindowLayout.swift`. Tests: `Tests/MeetingWindowLayoutTests.swift`. Callers: the `MeetingRootView` files in `App/UI/MeetingWindow/`. Style model: `App/UI/MeetingToolbarLayout.swift`.

This spec records what the Meeting window does today. It is a refactor: no behaviour or pixel changes. Where today's behaviour looks odd, the requirement says so under "Quirk" and the rule keeps it. Tile rectangles themselves (the gallery grid, the strip, Multi-speaker, the split) are already rules in `MeetingVideoLayout` and `MeetingSplit` (`App/UI/MeetingVideo/MeetingViewRules.swift`) and are not repeated here.

All rectangles are in AppKit coordinates (origin bottom left).

## Terms

- **Stage area**: the part of the window between the top bar and the toolbar, without the side panel column when there is one.
- **Area**: the stage area, or the video part of it when a share sits beside it.
- **Strip**: the row of small tiles in Speaker and Multi-speaker.
- **Slot form**: the small placed window with no permanent top bar or toolbar.

## Requirements

### R1. Narrow
The window is narrow when its width is below 900. At exactly 900 it is not narrow.
Status: built.

### R2. Gallery page size
Gallery shows as many people per page as fit at about 260 by 150 each: `Int(width / 260) * Int(height / 150)`. Fewer than 2 gives 1 person, fewer than 4 gives 2, fewer than 6 gives 4, fewer than 9 gives 6, fewer than 12 gives 9, otherwise 12. A grid with no width or no height gives 9.
Status: built.

### R3. Speaker and Multi-speaker page size
Speaker lists as many people as the strip holds. Multi-speaker lists its large tiles (at least 1) plus what the strip holds.
Status: built.

### R4. Strip capacity and your reserved end
The strip holds what `MeetingVideoLayout.stripCapacity` says for the grid width minus the reserved right end (never below 0), at tile height `stripHeight - 8`. Only Multi-speaker reserves a right end, and only while your own picture is shown: your preview's width plus 8.
Status: built.

### R5. Your preview in a strip
In a strip your preview is 16 by 9 at tile height `stripHeight - 8`, with the width rounded to a whole point.
Status: built.

### R6. Pages
The page count is the listed people divided by the page size, rounded up, and never below 1. A page is its slice of the list; a page that starts beyond the end is empty. A page is the last page when `(page + 1) * perPage >= listed`, so with nobody listed every page is the last.
Quirk: the page index is not clamped here; the window clamps it when the list changes.
Status: built.

### R7. Window regions
The full form reserves the top bar at the top and the toolbar at the foot; the stage area is what is left and its height never goes below 0. The slot form reserves nothing (its bars lie over the video).
Status: built.

### R8. Side panel and the narrow overlay
The side panel is 320 wide, or the window's width if that is smaller. It sits at the right edge, as tall as the stage area. In a wide window it takes a column off the stage area. In a narrow one it overlays the stage area's right edge and the stage area keeps its full width. In both, "clear right" (what the panel does not cover) is the window width minus the panel width; with no panel it is the window width.
Status: built.

### R9. Your preview
Your preview's right limit is the smaller of the area's right edge and clear right. It is in the strip when your picture is shown and either Speaker has other people or Multi-speaker has people beyond the large tiles. In the strip it is 16 by 9 (R5); otherwise it is 192 by 108.
- Gallery, or Speaker with nobody else: bottom right of the area, 12 in from the right and from the bottom.
- Speaker, in the strip: top right of the area, 4 in from the right and the top.
- Multi-speaker, in the strip: bottom right, a tile gap in from the right and from the bottom.
Status: built.

### R10. Grid host
- Gallery: the area inset by the tile gap on every side.
- Speaker: a band along the top of the area, as tall as the strip (the strip height, or 0 with nobody else), from the area's left to the right limit. When your preview is in the strip the band stops short of it by its width plus 8.
- Multi-speaker: the area inset by the tile gap, with the right limit as its right edge.
Status: built.

### R11. Stage host
In Speaker the stage is the area inset by 4 on every side, less the strip band from its height (the band is 0 with nobody else). Quirk: it ignores the right limit, so in a narrow window it runs under the side panel.
Status: built.

### R12. Empty note
The "waiting for others" note is 80 high, centred vertically on the area, starts 40 in from the area's left and is as wide as the right limit allows less 80 total, never under 80.
Status: built.

### R13. Share card, chip and share area
Your own share's card is centred in the stage host. The share chip is 26 high, centred on the stage, 12 below its top, as wide as its text plus 24 but no wider than the stage minus 24. Quirk: for a stage under 24 wide the chip's width goes negative. With no share beside, the share area is the stage up to clear right.
Status: built.

### R14. Inspector drawer
The selected person's drawer is 300 wide, its right edge 16 left of clear right, its top 16 below the stage's top. Its height is what it wants, no more than the stage's height minus 32. Quirk: for a stage under 32 high the height goes negative.
Status: built.

### R15. Pager arrows
Two arrows 30 by 56, vertically centred on the grid host: the first 6 in from its left, the second 6 in from its right.
Status: built.

### R16. Side panel parts
The head is 44 high. The body is the panel under the head. The close button is 24 square, 12 in from the right, 10 below the head's bottom edge. The title is 16 from the left, centred in the head, as wide as its text but no wider than the panel less 64 (never below 0). The divider is a 1 wide line down the left edge.
Status: built.

### R17. Participants panel: queue and roster
The needs block and Cues take the height they want, up to 45% of the body (rounded); nothing wanted means no height. They sit at the top of the body; the roster has the rest, never below 0.
Status: built.
