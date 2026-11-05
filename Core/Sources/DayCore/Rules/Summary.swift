import Foundation

/// The two sentences above a day, deterministic from event fields: counts, spans and
/// overlaps, no model. Pass merged events from visible calendars covering `day` and the day
/// after it, which sentence two may name.
///
/// Sentence one is exactly one of: out of office; nothing scheduled; the day listed (before
/// the first start, or any past or future day); how many are left; the last one; done.
/// Sentence two is the first of five rules that matches something still ahead and repeats
/// no time already in sentence one; when none does, there is no sentence two.
///
/// A time named on another day than `day` carries its weekday (`9:30 to Fri 0:15`, `Overnight
/// at Tue 22:00`), in the form of `Formatting.dayTime`. Which events are counted, which are
/// remaining and where the gaps fall still go by the part of each event that sits on `day`;
/// only the words use the event's own start and end, so a range never reads as ending before
/// it starts and an event that began the evening before says so.
public func summarize(day: CivilDate, events: [Event], now: Date, calendar: Calendar) -> Summary {
    let spans = daySpans(on: day, events: events, calendar: calendar)
    let context = SummaryContext(
        day: day,
        now: now,
        calendar: calendar,
        events: events,
        isToday: CivilDate(now, in: calendar) == day,
        spans: spans,
        remaining: spans.filter { $0.end > now })
    let first = context.firstSentence()
    return Summary(first: first.text, second: context.secondSentence(after: first))
}

/// A sentence and the times it names, as the reader sees them, so sentence two can avoid
/// repeating one.
private struct Sentence {
    var text: String
    var times: Set<String> = []
}

private struct SummaryContext {
    var day: CivilDate
    var now: Date
    var calendar: Calendar
    var events: [Event]
    var isToday: Bool
    /// Counted events on the day, earliest first.
    var spans: [DaySpan]
    /// Counted events on the day that have not ended: in progress or still to come.
    var remaining: [DaySpan]

    func t(_ date: Date) -> String {
        Formatting.time(date, calendar: calendar)
    }

    /// Where the event itself starts, with its weekday when that is not `day`.
    func startText(_ span: DaySpan) -> String {
        Formatting.dayTime(
            span.event.time.start(in: calendar), seenFrom: day, calendar: calendar)
    }

    /// Where the event itself ends, with its weekday when that is not `day`.
    func endText(_ span: DaySpan) -> String {
        Formatting.dayTime(span.event.time.end(in: calendar), seenFrom: day, calendar: calendar)
    }

    /// The latest true end among `list`, which is what `done at` and `9:30 to 17:00` name.
    func lastEnd(of list: [DaySpan]) -> DaySpan? {
        list.max { $0.event.time.end(in: calendar) < $1.event.time.end(in: calendar) }
    }

    // MARK: Sentence one

    func firstSentence() -> Sentence {
        if let away = wholeDayOutOfOffice(on: day, events: events, calendar: calendar) {
            // The block ends on a later day only when it still covers one after this one;
            // on its last day it is plainly out of office.
            if coveredDays(away, calendar: calendar).upperBound > day {
                let back = outOfOfficeReturn(away, calendar: calendar)
                return Sentence(
                    text: "Out of office until \(Formatting.until(back, from: day, calendar: calendar)).")
            }
            return Sentence(text: "Out of office.")
        }
        guard let firstSpan = spans.first else {
            return Sentence(text: "Nothing scheduled.")
        }
        if !isToday || now < firstSpan.start {
            return listing()
        }
        guard let nextUp = remaining.first else {
            return Sentence(text: "Done for today.")
        }
        if remaining.count >= 2 {
            let done = endText(lastEnd(of: remaining)!)
            return Sentence(
                text: "\(Formatting.countCapitalized(remaining.count)) to go, done at \(done).",
                times: [done])
        }
        if nextUp.start > now {
            let start = startText(nextUp)
            return Sentence(text: "One to go: \(nextUp.event.title) at \(start).", times: [start])
        }
        let end = endText(nextUp)
        return Sentence(text: "Last one: \(nextUp.event.title), until \(end).", times: [end])
    }

    /// The whole day, for a day not yet started or not today.
    private func listing() -> Sentence {
        switch spans.count {
        case 1:
            let start = startText(spans[0])
            return Sentence(text: "One event: \(spans[0].event.title) at \(start).", times: [start])
        case 2:
            let a = startText(spans[0])
            let b = startText(spans[1])
            return Sentence(
                text: "\(spans[0].event.title) at \(a) and \(spans[1].event.title) at \(b).",
                times: [a, b])
        default:
            let noun = spans.allSatisfy { $0.event.hasOtherAttendees } ? "meetings" : "events"
            let from = startText(spans[0])
            let to = endText(lastEnd(of: spans)!)
            return Sentence(
                text: "\(Formatting.countCapitalized(spans.count)) \(noun), \(from) to \(to).",
                times: [from, to])
        }
    }

    // MARK: Sentence two

    func secondSentence(after first: Sentence) -> String? {
        let rules: [() -> Sentence?] = [
            outOfOfficeStillOn, overlap, oneOffs, freeBlock, tomorrow,
        ]
        for rule in rules {
            if let sentence = rule(), sentence.times.isDisjoint(with: first.times) {
                return sentence.text
            }
        }
        return nil
    }

    /// 1. Out of office with a counted event ahead.
    private func outOfOfficeStillOn() -> Sentence? {
        guard wholeDayOutOfOffice(on: day, events: events, calendar: calendar) != nil,
            let ahead = remaining.first
        else { return nil }
        let start = startText(ahead)
        return Sentence(text: "\(ahead.event.title) at \(start) is still on.", times: [start])
    }

    /// 2. Two events that overlap and are not both over, the one that starts first. A free
    /// event never overlaps: it is shown as available.
    private func overlap() -> Sentence? {
        let pool = remaining.filter { !$0.event.isFree }
        var best: (a: DaySpan, b: DaySpan, at: Date)?
        for i in pool.indices {
            for j in pool.indices where j > i && pool[i].overlaps(pool[j]) {
                let at = max(pool[i].start, pool[j].start)
                if best == nil || at < best!.at { best = (pool[i], pool[j], at) }
            }
        }
        guard let best else { return nil }
        // Said from the later of the two real starts: two events carried over from the
        // evening before began overlapping then, not at midnight.
        let start = Formatting.dayTime(
            max(best.a.event.time.start(in: calendar), best.b.event.time.start(in: calendar)),
            seenFrom: day, calendar: calendar)
        return Sentence(
            text: "\(best.a.event.title) and \(best.b.event.title) overlap at \(start).",
            times: [start])
    }

    /// 3. Some but not all of what is left are one-offs.
    private func oneOffs() -> Sentence? {
        let singles = remaining.filter { !$0.event.isRecurring }
        guard !singles.isEmpty, singles.count < remaining.count else { return nil }
        let starts = singles.map { startText($0) }
        switch singles.count {
        case 1:
            return Sentence(
                text: "\(singles[0].event.title) at \(starts[0]) is the only one-off.",
                times: Set(starts))
        case 2:
            return Sentence(
                text: "One-offs: \(singles[0].event.title) at \(starts[0]) and \(singles[1].event.title) at \(starts[1]).",
                times: Set(starts))
        default:
            return Sentence(
                text: "One-offs: \(singles[0].event.title), \(singles[1].event.title) and \(Formatting.more(singles.count - 2)).",
                times: Set(starts.prefix(2)))
        }
    }

    /// 4. The first free block still ahead, or the one now is in. The same threshold and the
    /// same events as the Day list's gap rows.
    private func freeBlock() -> Sentence? {
        guard let gap = freeGaps(spans).first(where: { $0.end > now }) else { return nil }
        let end = t(gap.end)
        if gap.start <= now {
            return Sentence(text: "Free until \(end).", times: [end])
        }
        let start = t(gap.start)
        return Sentence(text: "Free from \(start) to \(end).", times: [start, end])
    }

    /// 5. Nothing left today, and tomorrow has something.
    private func tomorrow() -> Sentence? {
        guard isToday, remaining.isEmpty,
            let first = daySpans(on: day.adding(days: 1), events: events, calendar: calendar).first
        else { return nil }
        let start = t(first.start)
        return Sentence(text: "Tomorrow starts at \(start) with \(first.event.title).", times: [start])
    }
}
