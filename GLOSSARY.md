# Glossary

Words this codebase uses on purpose. Code lives in `App/SessionPhase.swift`.

## Session

The time Greenroom has its picture up: the cameras, the screen capture and the
composited picture. A session is either a **meeting** (the picture goes to a
Zoom meeting) or a **record** session (no meeting, only a take being made).
It is in one of four states:

- **Idle**: nothing is up.
- **Starting**: the start task is running (building the picture, joining the
  meeting, or counting down in Record). The picture may already be up.
- **Live**: the start task has finished and the picture is up.
- **Stopping**: Stop was asked for and the teardown has not finished. What was
  underneath (a start still in flight, the picture) stays until it does.

## Take

One recording file, made while a session is up. It is **none**, **rolling**,
**paused** (the file is not growing; resuming carries on in the same file) or
**saving** (stopped, the file is still being closed). A take is not part of
the session's state: a meeting can run with no take, and **saving can outlive
the session** (End Session stops the tape and closes the file in the background).
