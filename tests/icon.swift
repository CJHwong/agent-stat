import Foundation

// The menu bar: the icon's highlight, and how often the clock that moves it runs.

func testTickCadence() {
    print("the clock cadence")
    checkEqual(TickClock.cadence(panelOpen: true, screenAwake: true, busy: false), 1,
               "an open panel ticks every second for the ages")
    checkEqual(TickClock.cadence(panelOpen: false, screenAwake: true, busy: true),
               TimeInterval(StatusIcon.Stepper.secondsPerStep),
               "a busy closed panel ticks for the icon")
    checkEqual(TickClock.cadence(panelOpen: false, screenAwake: true, busy: false), 5,
               "an idle closed panel ticks slowly")
    checkEqual(TickClock.cadence(panelOpen: false, screenAwake: false, busy: true), 5,
               "a sleeping screen slows a busy panel too")
    checkEqual(TickClock.cadence(panelOpen: true, screenAwake: false, busy: true), 5,
               "a sleeping screen slows an open panel too")
}

func testIconStepper() {
    print("the icon stepper")
    var stepper = StatusIcon.Stepper()
    checkEqual(stepper.advance(working: false, second: 100), 0, "idle draws the first row")
    // Ten ticks in one second are one step, not ten: a record can tick more than once
    // a second, and an image per tick is what made the icon flicker.
    let first = stepper.advance(working: true, second: 100)
    checkEqual(first, 1, "work starts the highlight on the second row")
    for _ in 0..<9 { _ = stepper.advance(working: true, second: 100) }
    checkEqual(stepper.advance(working: true, second: 100), first,
               "ticks inside one second draw the same row")
    checkEqual(stepper.advance(working: true, second: 101), first,
               "one second is not yet a step")
    checkEqual(stepper.advance(working: true, second: 102), first,
               "two seconds is not yet a step")
    checkEqual(stepper.advance(working: true, second: 103), 2, "the interval moves to the next row")
    let later = [106].map { stepper.advance(working: true, second: $0) }
    checkEqual(later, [0], "one row per interval, wrapping over the three rows")
    checkEqual(stepper.advance(working: false, second: 108), 0, "the work ends on the first row")
    checkEqual(stepper.advance(working: false, second: 110), 0, "and stays there")
}
