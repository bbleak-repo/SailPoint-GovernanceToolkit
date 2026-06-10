# Manager Attestation Guide -- Business IT User Review

**Reviewer Profile:** IT Operations staff, moderate IT knowledge, familiar with Active Directory and privileged access concepts, has used SailPoint ISC a handful of times.

**Files Reviewed:**
- `Manager-Attestation-Guide.html` (linear/scrollable version)
- `Manager-Attestation-Guide-Tabbed.html` (tabbed SPA version)

**Date:** 2026-06-06

---

## 1. Structure and Organization

**Rating: 4/5**

The document follows a logical progression: why (Sections 1-3), how to talk about it (Section 4), how to do it (Sections 5-7), examples (Section 8), accountability (Sections 9-10), reference (Sections 11-13). That arc makes sense and I would generally read it top-to-bottom the first time, then jump to Sections 5-8 and 12 for repeat visits.

**What works well:**
- The "why before how" ordering is the right call. Managers need to understand the stakes before they are told which buttons to click. If you lead with the UI walkthrough, people treat it as a task to complete rather than a responsibility to own.
- The table of contents in the linear version and the welcome landing page in the tabbed version both do a good job of orienting the reader. The welcome page's card groupings (The Why / Talking to Your Team / Using the Interface / etc.) are especially helpful because they reduce 13 sections into 6 logical clusters.
- Glossary at the end is the right place for it.

**What could improve:**
- Sections 9 and 10 feel like they should come earlier -- or be folded into Sections 3 and 4. By the time I reach "Avoiding Rubber-Stamping" on Section 9, I have already been warned about rubber-stamping twice (Section 3 warning callout and Section 6.4 caution callout). The rubber-stamping detection table in Section 9 is genuinely useful, but it arrives too late. It would land harder right after Section 3's stat badges.
- Section 10 ("The Least-Privilege Mindset") feels like a restatement of things already said in Sections 1-4. The three-tier framing (for team members / for you / for the organization) is nice, but every individual bullet point has already been covered. This section could be cut to a callout box without losing substance.
- The checklist (Section 12) would be more useful right after Section 6 (the decision-making section), not separated by two sections of philosophy. When I am in the "how do I actually do this" mindset, I want the checklist within reach.
- 13 sections is a lot. Most managers will see the table of contents and think "I do not have time for this." Consolidating Sections 9-10 into Section 3, and moving Section 12 to follow Section 6, would tighten the document to 11 sections and improve the flow.

---

## 2. Content Clarity and Accuracy

**Rating: 4/5**

**Accurate and well-explained:**
- The distinction between campaign, certification, and attestation is handled well, both inline and in the glossary. This is a genuine source of confusion and the document addresses it without being pedantic.
- The explanation of automated/birthright roles showing "Acknowledge" instead of "Approve" is a detail that trips up real users. Good inclusion.
- The remediation table in Section 6.2 (automated vs. manual/disconnected sources) is accurate and practical. People need to know that clicking "Revoke" does not always mean instant removal.
- The reassignment rules (cannot self-certify, cannot reassign after sign-off) are correct and important guardrails to document.

**The Four Questions framework (Section 4.1):**
- Practical and usable. Question 4 ("What happens if you lose this access tomorrow?") is especially well-designed because it forces the employee to self-assess. In my experience, most people will honestly admit they have not used something in months if you ask the right way.
- One gap: the framework assumes the manager is having a live conversation with the employee. In practice, many managers will be reviewing a campaign at 8pm after the employee has gone home. A note about how to make the decision independently (using activity timestamps, peer comparison data, last-used dates in ISC) would bridge that gap.

**The 5 scenarios (Section 8):**
- Scenarios 1-3 are the most realistic and the ones I would actually encounter. The new-hire template problem and the role-transfer privilege accumulation are things I deal with regularly.
- Scenario 4 (legitimate access) is a smart inclusion -- it signals that the document is not trying to push revocation for its own sake.
- Scenario 5 (reassignment) is necessary but could use more detail. It says to reassign to "the application owner or technical lead" -- but how do I find out who that is? In SailPoint ISC, is there a way to look up the source owner? This is a real friction point.

**Missing scenarios I would add:**
- **Contractor/vendor access:** A contractor on your team has the same privileged access as full-time employees. The considerations are different (contract end dates, SOW scope, vendor risk).
- **Shared/service account:** A campaign surfaces a service account that your team "owns" but nobody personally uses day-to-day. Do you approve it? Reassign it? Who is the right reviewer for a non-human identity?
- **The employee who just gave notice:** Someone on your team put in their two weeks. Do you revoke now or wait for the termination process?

**Oversimplifications:**
- The document says revocation is "generally permanent" (Section 6.2). This is technically true in the certification context, but it might scare managers away from revoking. A more accurate framing: "Revocation removes the access. If the person needs it again, they submit a standard access request, which typically takes [X hours/days] to process." Giving a concrete turnaround time would reduce the fear factor.
- The stat badges claim "74% of data breaches involve misuse of privileged credentials (DBIR)." The Verizon DBIR numbers change annually and the specific claim depends on which year and which metric you use. I would soften this to "A majority of data breaches" or cite the specific DBIR year. Same concern with the "75%+" rubber-stamping stat -- where does that number come from?

---

## 3. Visual Design and Formatting

**Rating: 4/5 (Linear) | 4.5/5 (Tabbed)**

**Linear version:**
- Clean, professional layout. The 850px max-width is comfortable for reading. Font choices (Segoe UI, Calibri) are appropriate for a corporate document.
- The callout boxes are well-differentiated by color and serve their purpose (tip = green, note = blue, warning = orange, important/critical = red). The color coding is intuitive.
- The stat badges in Section 3 are visually striking and make the risk argument visceral. The large red numbers draw the eye.
- The flow diagrams (CSS-only step progressions) are a nice touch. Simple, no external dependencies, and they convey the process clearly.
- The comparison cards (Source Owner vs Manager, Identities View vs Access Items View) are effective at presenting binary choices.
- The print styles are a thoughtful inclusion -- the `break-inside: avoid` on scenarios and callouts prevents awkward page breaks.

**Tabbed version:**
- The sticky tab bar with numbered tabs is a significant UX improvement for repeat reference. Once you know the document, you can jump straight to Section 6 or Section 12 without scrolling.
- The welcome page hero with clickable cards is an excellent landing experience. It answers "what is this and where should I start?" in under 5 seconds.
- The FAQ accordion (click-to-expand) is much better than the linear version's flat list. Nine questions visible as a scannable list is more approachable than nine visible question-and-answer pairs.
- The glossary grid (2-column card layout) is visually cleaner than the linear version's table. Both work, but the grid feels more modern.
- The keyboard navigation (left/right arrows) is a nice power-user feature, though I doubt most managers will discover it.
- The fade-in animation on tab switch is subtle and professional. It does not feel gratuitous.

**Issues:**
- The tab bar on the tabbed version has 14 buttons (Home + 13 sections). On a smaller screen or a normal laptop, this wraps to two rows or requires horizontal scrolling. The tab labels are terse ("Why Daily", "Manager Shift", "Priv Risk") but even so, 14 tabs is a lot. Grouping some tabs (e.g., combining Sections 9-10 into one tab, combining Sections 12-13 into one tab) would reduce this to 11-12 tabs and fit more comfortably.
- In the linear version, the scenario cards all look identical. Adding a small colored accent (green border for "legitimate access" in Scenario 4, red border for "revoke" scenarios) would make the outcomes scannable.
- The `code` styling (red text on light gray) for technical terms like `GRANT_ACCESS` is fine for an IT audience, but some managers might find it jarring. It is a minor point.
- The tone table in the tabbed version (Section 4.2) applies strikethrough to the "Instead of" column, which is a nice visual cue but slightly reduces readability. The linear version's plain table is clearer.

---

## 4. Gaps and Improvements

**Rating: 3/5**

This is where the biggest opportunities lie.

**Screenshots of the SailPoint ISC interface:**
- Yes, absolutely. The document describes the UI in words ("campaign cards," "Active tab," "checkmark icon," "Bulk Decisions button") but never shows it. For someone who has used ISC a few times, the words are enough. For someone opening ISC for the first time with this guide in hand, they would be hunting for UI elements described only in text.
- Specific places where screenshots would help most:
  - Section 5.1: What does the Certifications page look like? Where is the "Active" tab?
  - Section 5.2: The Identities vs Access Items toggle -- where is it on the screen?
  - Section 5.3: What do the access flags (privileged, birthright, new) actually look like?
  - Section 6.1: The Approve/Revoke icons -- what do they look like?
  - Section 6.4: The bulk selection and Bulk Decisions button
  - Section 7: The sign-off page
- Even 3-4 annotated screenshots would dramatically improve the document's usability for first-time reviewers.

**Quick-start "I just got a campaign notification" section:**
- This is a significant gap. The most common entry point to this document will be a manager who just received an email from SailPoint ISC saying they have items to review. They want to know: (1) where do I go, (2) what do I click, (3) how do I finish. A 2-minute quick-start at the very top of the document (or as a dedicated "Quick Start" tab in the tabbed version) would serve this use case. Something like:
  1. Click the link in the email notification
  2. Review each item -- look at the privileged flag and last activity date
  3. Approve (checkmark) or Revoke (X) each item
  4. Add a brief comment for privileged items
  5. Click Sign-Off when done
- This does not replace the full guide, but it gives the impatient manager a path to completion while signaling that the rest of the document exists for deeper understanding.

**Decision flowchart:**
- Yes. The checklist in Section 12 is good, but a visual decision tree would be more effective for the core approve/revoke decision. Something like:
  - Does the person still hold this role? No -> Revoke
  - Have they used this access in the past 90 days? No -> Ask them (or Revoke)
  - Is there a lower-privilege alternative? Yes -> Revoke and request the alternative
  - Is the access time-bound? Yes -> Approve with a note to review at expiration
  - None of the above? -> Approve with a comment
- A CSS-only or simple HTML flowchart in the same style as the existing flow diagrams would work here.

**Missing content:**
- **Email notification example:** What does the campaign notification email look like? What is the subject line? Managers get a lot of email -- knowing what to look for would help.
- **Time commitment estimate:** The document says daily reviews are "smaller" but never says how long one takes. A concrete estimate ("most daily delta reviews take 5-10 minutes") would reduce anxiety.
- **Escalation path:** If I have a question about an entitlement or need to discuss a decision, who do I contact? "The IAM team" is referenced throughout but never identified. A placeholder like "[Your IAM team contact]" with a note to customize would be better than the generic reference.
- **Mobile access:** Can managers review campaigns on a phone or tablet? Many managers are not at a desk all day.

**Jargon concerns:**
- "SailPoint VA" (Virtual Appliance) is used in Section 6.2 without explanation. Most managers would not know what a VA is.
- "Lifecycle state assignments" and "membership criteria" in the FAQ could use a parenthetical example.
- "Remediation pipeline" (Section 7) is IAM jargon that could be "removal process" for this audience.
- "Source Owner" is used in Section 2 assuming the reader knows this SailPoint concept. A brief inline definition would help.
- "DBIR" in the stat badge is not expanded anywhere in the document (Verizon Data Breach Investigations Report).

---

## 5. Tone and Approachability

**Rating: 4.5/5**

**What works:**
- The tone is respectful of the reader's time and intelligence throughout. It does not talk down to managers -- it treats them as capable professionals who need context, not hand-holding. This is the right calibration for IT operations staff.
- The "professional hygiene" framing in Section 4.2 is excellent. Comparing least privilege to hygiene (something you do regularly as a matter of course, not something imposed on you) is a smart rhetorical move.
- The conversation reframing table ("Instead of... / Try...") is genuinely useful and avoids being preachy. It acknowledges that the way you say things matters, without being condescending about it.
- Section 8, Scenario 4 (legitimate access) and the line "Not every review results in a revocation. The goal is informed decisions, not maximum revocations" is a critical sentence. It prevents the document from feeling like a revocation-pressure tool.
- The FAQ answers are concise and direct. No padding, no filler.

**Where it slightly misses:**
- The accountability language in Sections 3, 9, and the warning/important callouts walks a fine line. Phrases like "you are personally attesting," "you may be interviewed about specific approvals," and "your decisions will be flagged" are factually accurate but cumulatively feel heavy. By Section 9, the reader has been warned about audit consequences four or five times. It starts to feel like the document is trying to scare compliance into people rather than enable good decisions. I would keep the strongest version (the Section 9 callout about audit interviews) and soften the earlier instances.
- The blockquote in Section 4.3 ("What to tell your team") reads naturally and sounds like something a real manager would say. Good job on that.

**Consistency:**
- Tone is consistent from start to finish. No jarring shifts between sections. Both versions maintain the same voice.

---

## 6. Specific Issues

### Sentences/Sections to Reword

1. **Section 3, personal attestation list item 4:** "You accept accountability for this decision" -- This is vague. Accountability to whom? For what consequence? Either make it concrete ("You are the named approver in the audit record") or remove it, since items 1-3 already establish the substance of what you are attesting.

2. **Section 6.2, revocation warning:** "Revocation is generally permanent." The word "permanent" is misleading. The *access removal* is immediate, but the person can re-request access. Suggest: "Revocation removes the access immediately. Re-granting requires a new access request through the standard process."

3. **Section 7, missed deadline:** "SailPoint strongly recommends maintaining access for undecided items." This reads like a product recommendation, not organizational policy. In a manager-facing guide, this should say something like "Our organization's policy for undecided items is [maintain/revoke]." The current phrasing makes it unclear whether this is what *our* org does or what SailPoint suggests.

4. **Section 9, "take at least 15-30 seconds per item":** This is oddly specific and somewhat patronizing. It implies that the measure of a good review is spending a minimum amount of time, rather than actually thinking about the decision. Suggest removing the time guidance and focusing on what to actually evaluate.

5. **Section 2, intro paragraph:** "This model has a fundamental limitation" -- Strong claim. Some organizations run effective source-owner campaigns. Suggest: "This model has a key limitation in the privileged access context" to scope the claim appropriately.

### Factual Claims Needing Citations or Softening

1. **"74% of data breaches involve misuse of privileged credentials (DBIR)"** -- Needs a specific year citation. The DBIR methodology and findings change annually. If the 2025 DBIR says 68%, the stat is stale.

2. **"75%+ of organizations acknowledge rubber-stamping as a problem"** -- No source cited at all. This looks like it might come from a SailPoint or Gartner survey, but without attribution it reads as made-up.

3. **"<10s average time reviewers spend per decision when rubber-stamping"** -- Source? This is plausible but uncited. If this comes from SailPoint's own telemetry, say so.

### HTML/CSS Issues

1. **Linear version, line 760:** The callout at Section 6.1 uses `callout-note` class but the label text says "Important" -- the class should arguably be `callout-important` to match the label and get the red styling. As-is, the blue note styling with an "Important" label is a visual mismatch.

2. **Tabbed version:** The `callout-warn` and `callout-danger` class names differ from the linear version's `callout-warning` and `callout-important`. This is not a bug (they are separate files with separate CSS), but it would make future maintenance easier if the class names were consistent across versions.

3. **Tabbed version, line 604:** The `@media print` rule shows all tab panels, which is correct for printing, but the `page-break-before: always` on every panel will produce a lot of blank space if a section is short (e.g., Section 7 Sign-Off is maybe half a page of content). Consider using `page-break-before: auto` with `page-break-inside: avoid` on cards and callouts instead.

4. **Tabbed version:** No `<meta>` description tag. Not critical, but if this gets shared via URL preview (Slack, Teams), there will be no preview snippet.

5. **Linear version:** The print media query has `break-after: page` on `.cover-block` and `break-after: avoid` on `h2`. The `break-after` property is not universally supported in older print engines. For maximum print compatibility, consider duplicating with `-webkit-` prefixed versions or using `page-break-after` as a fallback.

6. **Tabbed version, FAQ section:** The `onclick="this.parentElement.classList.toggle('open')"` inline JavaScript handlers work fine, but they will not be accessible to keyboard-only users. The FAQ questions are `<div>` elements, not `<button>` or elements with `tabindex`. A keyboard user cannot tab to a question or press Enter to expand it.

---

## Summary Scorecard

| Category | Rating | Notes |
|---|---|---|
| Structure and Organization | 4/5 | Logical arc but could tighten Sections 9-10 and relocate the checklist |
| Content Clarity and Accuracy | 4/5 | Solid ISC content, practical framework, needs contractor/service account scenarios |
| Visual Design and Formatting | 4/5 (linear), 4.5/5 (tabbed) | Professional and clean; tabbed version is the stronger format |
| Gaps and Improvements | 3/5 | Missing quick-start, screenshots, decision flowchart, and escalation contacts |
| Tone and Approachability | 4.5/5 | Respectful and consistent; slightly heavy on audit-threat language by Section 9 |
| Specific Issues | -- | 6 sentences to reword, 3 uncited stats, 6 HTML/CSS issues |

**Overall: 4/5**

This is a solid first version that I would be comfortable distributing to managers today. The content is accurate, the scenarios are useful, and the tone is right. The tabbed version is the better delivery format for ongoing use; the linear version is better for initial read-through or printing.

The highest-impact improvements for v2, in priority order:

1. **Add a quick-start section** (30 seconds to read, covers the "I just got an email, what do I do" case)
2. **Add 3-4 annotated ISC screenshots** (campaign list, review screen, approve/revoke buttons, sign-off page)
3. **Add a visual decision flowchart** to complement the checklist
4. **Consolidate Sections 9-10** into Section 3, and move the checklist to follow Section 6
5. **Cite or soften the statistics** in Section 3
6. **Add contractor and service account scenarios** to Section 8
7. **Fix the FAQ keyboard accessibility** in the tabbed version
