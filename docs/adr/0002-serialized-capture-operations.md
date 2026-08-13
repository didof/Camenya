# ADR-0002: Serialize capture operations on one queue

Status: Accepted

## Context

AVCaptureSession configuration, input replacement, connection changes, and file-output operations are order-sensitive and may block. SwiftUI state belongs on the main actor.

## Decision

A dedicated serial queue owns all capture-session mutations. Delegate completions feed the Take state machine, and user-visible state is published on the main actor. Unsafe concurrency annotations are localized only where an AVFoundation callback boundary makes them unavoidable.

## Consequences

SwiftUI views never mutate the session. Transition completion is event-driven, conflicting controls remain disabled while work is pending, and arbitrary delays are forbidden.
