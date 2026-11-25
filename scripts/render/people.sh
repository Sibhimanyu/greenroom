#!/bin/bash
# The Participants list off screen, sample data: a host's view with one row under
# the pointer (Mute and "..."), the person menu and the footer's "..." menu as
# the rules build them. Usage: scripts/render/people.sh [outdir]
# (default $TMPDIR/greenroom-render/people)
NAME=people; source "$(dirname "$0")/lib.sh"
write_brand
# The pop-up menu is an AppKit bridge; a clear stand-in keeps the layout.
printf 'import SwiftUI\nstruct MenuPopUpOverlay: View { let label: String; var below = false; let entries: () -> [MenuEntry]; var body: some View { Color.clear } }\n' > "$STAGE/PopStub.swift"
# The shortcut model pulls in the whole layout model; menus only carry the type.
printf 'struct KeyCombo: Equatable {}\n' > "$STAGE/KeyStub.swift"
render people-render people-main.swift "$STAGE/Brand.swift" "$STAGE/PopStub.swift" "$STAGE/KeyStub.swift" \
  App/UI/ParticipantConsole/MeetingPeopleView.swift App/UI/ParticipantConsole/ParticipantActionRules.swift \
  App/UI/MeetingMenuSpec.swift App/UI/MeetingTheme.swift App/UI/VisibilitySymbols.swift \
  App/UI/PresentMenuSpec.swift App/Zoom/MeetingShareRules.swift App/Stage/CameraState.swift
finish
