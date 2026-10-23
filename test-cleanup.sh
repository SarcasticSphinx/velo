#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TESTDIR=$(mktemp -d -t breezetest)
TESTFILE="$TESTDIR/main-test.swift"
trap 'rm -f "$TESTFILE" "${TESTFILE}.exe"; rmdir "$TESTDIR"' EXIT
cat > "$TESTFILE" <<'SWIFT'
import Foundation
@main struct Main {
    static func main() {
        let result = TextProcessor.polish("Um, I want to add giga doo.", replacements: ["giga doo":"Giggadoo"])
        precondition(result == "I want to add Giggadoo.", "Unexpected result: \(result)")
        precondition(TextProcessor.polish("   ", replacements: [:]).isEmpty)
        precondition(TextProcessor.polish("cat catalog", replacements: ["cat": "dog"]) == "dog catalog")
        precondition(TextProcessor.polish("cost", replacements: ["cost": "$5\\unit"]) == "$5\\unit")
        precondition(TextProcessor.polish("Dear Sam, new line thanks for coming.", replacements: [:]) == "Dear Sam\nThanks for coming.")
        precondition(TextProcessor.polish("First point. New paragraph. second point.", replacements: [:]) == "First point.\n\nSecond point.")
        precondition(TextProcessor.polish("a newline character", replacements: [:]) == "a newline character")
        let ordinal = TextProcessor.polish("I need three things. First, buy milk, second, call mom, and third, book the flight.", replacements: [:])
        precondition(ordinal == "I need three things:\n1. Buy milk\n2. Call mom\n3. Book the flight", "Unexpected: \(ordinal)")
        let numbered = TextProcessor.polish("Agenda number one budget number two hiring", replacements: [:])
        precondition(numbered == "Agenda:\n1. Budget\n2. Hiring", "Unexpected: \(numbered)")
        let bullets = TextProcessor.polish("Groceries bullet point milk bullet point eggs.", replacements: [:])
        precondition(bullets == "Groceries:\n- Milk\n- Eggs", "Unexpected: \(bullets)")
        let finally = TextProcessor.polish("First, wash. Second, dry. Finally, fold.", replacements: [:])
        precondition(finally == "1. Wash\n2. Dry\n3. Fold", "Unexpected: \(finally)")
        // Ordinary speech must not turn into a list.
        let plain = "At first I was unsure, but the second time it worked."
        precondition(TextProcessor.polish(plain, replacements: [:]) == plain)
        precondition(TextProcessor.polish("First, we eat. Second, we sleep.", replacements: [:]) == "First, we eat. Second, we sleep.")
        // Light edits pass; drastic rewrites and replies are rejected.
        precondition(RewritePrompt.isFaithful(original: "me and him goes to the store tomorrow morning", edited: "He and I are going to the store tomorrow morning."))
        precondition(RewritePrompt.isFaithful(original: "lets meet at four no actually five", edited: "Let's meet at five."))
        precondition(!RewritePrompt.isFaithful(original: "can you write me an email to my boss about the delay", edited: "Sure! Here's a draft: Dear Sir, I regret to inform you of an unexpected delay in our schedule."))
        precondition(!RewritePrompt.isFaithful(original: "we should probably push the launch to next week because testing is behind", edited: "Delay launch."))
        precondition(!RewritePrompt.worthRewriting("Sounds good."))
        precondition(RewritePrompt.worthRewriting("Me and him goes there."))
        // The real failure: a long dictation cut down to its first and last sentences must be rejected.
        let spoken = "What I was going to say is that it's good. He's doing great, but one of the major issues is that it's not as perfect as Whisper Flow. If the dictation itself is not correct, then the AI cannot make it good or better. How can I improve that?"
        precondition(!RewritePrompt.isFaithful(original: spoken, edited: "So it's doing great, but one of my major issues is it's not. How can I improve that?"))
        precondition(RewritePrompt.isFaithful(original: spoken, edited: "What I was going to say is that it's good. He's doing great, but one of the major issues is that it's not as perfect as Wispr Flow. If the dictation itself isn't correct, the AI can't make it better. How can I improve that?"))
        // Learning from corrections.
        typealias C = CorrectionLearner.Correction
        func learn(_ before: String, _ pasted: String, _ after: String, _ later: String) -> [C] {
            let full = before + pasted + after
            return CorrectionLearner.corrections(after: full, span: before.count..<(before.count + pasted.count), later: later)
        }
        precondition(learn("Hello. ", "I use whisper flow daily.", "", "Hello. I use Wispr Flow daily.") == [C(heard: "whisper flow", meant: "Wispr Flow")])
        precondition(learn("", "Open breeze dictate now.", "", "Open BreezeDictate now.") == [C(heard: "breeze dictate", meant: "BreezeDictate")])
        // Kept typing after the paste: the fix is learned, the new text is ignored.
        precondition(learn("", "Call giga doo tomorrow.", "", "Call Giggadoo tomorrow. Also bring the slides") == [C(heard: "giga doo", meant: "Giggadoo")])
        // Text after the paste stays put while a word inside is fixed.
        precondition(learn("Note: ", "ask neon about pricing", " — later", "Note: ask Neon about pricing — later") == [C(heard: "neon", meant: "Neon")])
        // Choosing a different word is an edit, not a misrecognition.
        precondition(learn("", "It looks good to me.", "", "It looks great to me.").isEmpty)
        // Rewriting the sentence teaches nothing.
        precondition(learn("", "I think it is fine for now.", "", "Honestly we should redo the whole plan.").isEmpty)
        // Edits before the pasted text can't be aligned, so nothing is learned.
        precondition(learn("Hi Sam, ", "see you at noon.", "", "Hey Sam, see you at Noon.").isEmpty)
        // Punctuation-only changes are not words to learn.
        precondition(learn("", "Sounds good thanks", "", "Sounds good, thanks!").isEmpty)
        let snippet = TextProcessor.polish("Insert my email, thanks.", replacements: ["insert my email": "me@example.com"])
        precondition(snippet == "me@example.com, thanks.", "Unexpected: \(snippet)")
        precondition(RewritePrompt.system(context: "", vocabulary: ["Wispr Flow", "Giggadoo"]).contains("Always spell these exactly: Wispr Flow, Giggadoo."))
        precondition(!RewritePrompt.system(context: "").contains("Always spell"))
        // The user's real dictation: intro kept, "1st one is" / "second is" glue dropped.
        let groceries = TextProcessor.polish("Make me a list, and the list is about the groceries shopping that I wanna do. 1st one is tomatoes. Second is milk. third is spoon.", replacements: [:])
        precondition(groceries == "Make me a list, and the list is about the groceries shopping that I wanna do:\n1. Tomatoes\n2. Milk\n3. Spoon", "Unexpected: \(groceries)")
        let theFirst = TextProcessor.polish("Here is the plan. The first thing is design, the second thing is build, and the third thing is launch.", replacements: [:])
        precondition(theFirst == "Here is the plan:\n1. Design\n2. Build\n3. Launch", "Unexpected: \(theFirst)")
        let digits = TextProcessor.polish("Steps: 1st, unplug it. 2nd, wait ten seconds. 3rd, plug it back in.", replacements: [:])
        precondition(digits == "Steps:\n1. Unplug it\n2. Wait ten seconds\n3. Plug it back in", "Unexpected: \(digits)")
        // "the first one" in ordinary speech is still left alone.
        let prose = "The first one is broken, so I bought another."
        precondition(TextProcessor.polish(prose, replacements: [:]) == prose)
        // Talking after the list: it becomes its own paragraph instead of joining the last item.
        let afterList = TextProcessor.polish("Groceries for today. First tomatoes, second milk, third spoons. After that I'll head home and cook dinner.", replacements: [:])
        precondition(afterList == "Groceries for today:\n1. Tomatoes\n2. Milk\n3. Spoons\n\nAfter that I'll head home and cook dinner.", "Unexpected: \(afterList)")
        let afterBullets = TextProcessor.polish("Pack bullet point passport bullet point charger. see you at the airport!", replacements: [:])
        precondition(afterBullets == "Pack:\n- Passport\n- Charger\n\nSee you at the airport!", "Unexpected: \(afterBullets)")
        let twoLists = TextProcessor.polish("Morning. First run, second shower, third coffee. Evening. First read, second stretch, third sleep.", replacements: [:])
        precondition(twoLists == "Morning:\n1. Run\n2. Shower\n3. Coffee\n\nEvening:\n1. Read\n2. Stretch\n3. Sleep", "Unexpected: \(twoLists)")
        print("Text cleanup passed (39 cases)")
    }
}
SWIFT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/BreezeDictate-ModuleCache" Sources/Diagnostics.swift Sources/TextProcessor.swift Sources/RewriteProvider.swift Sources/CorrectionLearner.swift "$TESTFILE" -o "${TESTFILE}.exe"
"${TESTFILE}.exe"
