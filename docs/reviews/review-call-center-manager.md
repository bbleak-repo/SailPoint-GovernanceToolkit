# Manager Attestation Guide Review
## Perspective: Call Center Manager (Non-Technical)
**Reviewer Profile:** Call center manager, 15 direct reports, comfortable with email/Teams/CRM, zero Active Directory or identity governance experience.

**Date:** 2026-06-06

---

## First Impressions

**Rating: 2/5**

My honest first reaction when I opened this document was a knot in my stomach. The title alone -- "Manager's Guide to Privileged Access Attestation" -- made me feel like I had accidentally opened something meant for the IT department. I do not know what "attestation" means in this context. I do not know what "privileged access" means. I manage a phone queue, not a server room.

Within the first 30 seconds I understood that this has something to do with reviewing my team's access to... something. But I did not understand what I was supposed to *do*. The cover block talks about "daily delta certification," "reviewer interface," and "approve/revoke decisions for your team's privileged access." That is three pieces of jargon in one sentence. I am already lost.

The cover/header is visually polished and professional, but it is intimidating rather than reassuring. It looks like a compliance document, not a help guide. When I am panicking because I just got an email telling me to do something I have never heard of, I need the first thing I see to say something like: "You got an email asking you to review your team's access. Here is exactly what to do." Instead, I got a subtitle that sounds like it was written for an IAM architect.

The tabbed version's welcome page is slightly better because it groups things into clickable cards, but the card labels still assume I know what "Daily Delta Certification" and "ISC Experience" mean.

---

## Can I Actually Do My Job With This?

**Rating: 2/5**

After reading the entire guide, I have a *conceptual* understanding of what I need to do, but I do not have *procedural* confidence. There is a critical gap between theory and practice.

**The login gap is enormous.** Section 5.1 says "Log in to the SailPoint ISC admin console." Full stop. But:
- What is the URL? Where do I find it?
- What are my credentials? Are they the same as my Windows login? Do I need to request an account?
- If I click the link in the email I received, does it take me directly to my campaign, or do I land on a homepage and have to navigate?
- Is there multi-factor authentication? Will I need my phone?

These are not edge cases. These are the literal first thing I need to do, and the guide skips all of it.

**The interface description is text-only.** Section 5 describes "campaign cards," an "Active tab," "Identities view," and "checkmark/X icons," but I have never seen any of these. Without a single screenshot or annotated image, I am guessing at what the screen looks like. I would not recognize the "Approve" button if I saw it because I do not know if it is a green checkmark, a thumbs-up, a button that says "Approve," or something else entirely.

**The decision-making section (6) assumes I understand the access items.** It says to click Approve if "no lower-privilege alternative exists." How would I know that? I do not know what any of these AD groups do. If I see "CN=CRM_Users,OU=AppGroups,DC=corp,DC=local" in my campaign, this guide does not help me understand what I am looking at.

**Could I complete a 3-item campaign using only this guide?** Honestly, probably not on my first try. I would get as far as logging in (if I can figure out where), but then I would be staring at the screen unsure which buttons to click and unsure whether the things I am reviewing are things my team actually uses. I would end up calling the help desk.

---

## Language and Jargon

**Rating: 2/5**

### Terms That Confused Me or Required Mental Translation

| Term in Guide | My Reaction |
|---|---|
| Attestation | Had to look this up. The glossary says "formal confirmation that an access assignment is appropriate" -- but I would call this "confirming" or "signing off." Why the fancy word? |
| Entitlement | The glossary says "a specific permission in a target system." I still do not know what this means in practice. Is it a login? An app? A folder? |
| Access Profile | "A bundle of entitlements from one source." A bundle of what from one what? This definition requires me to already understand two other jargon terms. |
| Role (SailPoint sense) | "A business concept bundling access profiles across multiple sources." This is three layers of abstraction deep. I got lost at layer one. |
| Source | "A connected system from which accounts and entitlements are aggregated." In my world, a "source" is where a customer called from. |
| Remediation | I know this word from customer complaints, but here it means "removing access after revocation." The guide should just say "removing access." |
| Identity | The guide uses this to mean "a person in the system." Why not just say "person" or "employee"? |
| Delta certification | I have heard "delta" in the context of airline travel and river geography. Not access reviews. |
| GRANT_ACCESS event | This appears in a code-formatted box. I do not know what this is or where it comes from. It looks like something from a programming language. |
| Birthright (access) | The guide says some items are "birthright" access. This word confused me -- it sounds like something from a legal document. |
| Lifecycle state | Never explained in the main text. Appears in the FAQ answer about acknowledge-only items. |
| Source Owner | Section 2 contrasts this with manager reviews. I did not know "source owners" were a thing. |
| Blast radius | Used repeatedly. I understand the metaphor, but it feels alarmist. Maybe "impact" or "damage if something goes wrong" would be less dramatic. |
| SOX 404, SOC 2, ISO 27001, NIST 800-53 | These appear in a table in Section 3. I have no idea what any of them are. They are never explained. |
| Break-glass process | Section 4.4 and Scenario 3 reference this. I do not know what this means. |
| JIT (just-in-time) access | Same section. Not in the glossary. |
| SailPoint VA | Section 6.2 table. What is a VA? Not in the glossary. |
| IAM team | Referenced throughout. I think this is the IT security team? But the guide never says "your IT security team" or provides a contact. |

### Sentences With Too Much Jargon

- "The system detects the GRANT_ACCESS event from the previous 24 hours and groups affected identities by manager." -- This sentence has three jargon terms and a code reference. A non-technical manager would parse this as noise.
- "Items granted through automated membership criteria (birthright roles, lifecycle state assignments) cannot be revoked through certification." -- Every noun in this sentence is jargon.
- "For roles that were automatically assigned through membership criteria (birthright/lifecycle rules), the button says Acknowledge instead of Approve." -- Same problem.

### The Glossary

The glossary exists, which is good. But the definitions themselves use jargon to define jargon. "Remediation: The process of removing access after a revocation decision -- automatic (connected) or manual (disconnected)." What does "connected" vs "disconnected" mean? I do not know what those words mean in this context, and they are not in the glossary.

### Suggested Rewording Examples

| Current | Suggested Plain-English |
|---|---|
| "Daily delta certification" | "A daily review of any new access your team members received in the last 24 hours" |
| "Entitlement" | "A specific permission or access right -- for example, membership in a group that lets someone log into a server" |
| "The system detects the GRANT_ACCESS event" | "The system detects that someone on your team was given new access" |
| "Remediation pipeline" | "The process that actually removes the access you decided to revoke" |
| "Birthright access" | "Access that was automatically given based on someone's job title or department -- you cannot change this through the review" |

---

## What Scared or Confused Me

**Rating: 2/5**

### The Warnings Made Me Afraid to Touch Anything

The guide contains multiple warning callouts that made me feel like I was about to handle a live grenade:

- "Revocation is generally permanent." -- This terrified me. What if I click the wrong button? The guide says I can use "Revisit Decision" before sign-off, but what if I do not realize my mistake until after? The guide says "contact the IAM team" but does not tell me who they are or how to reach them.

- "Approving everything in under 10 seconds flags your decisions for additional scrutiny." -- So if I approve things quickly because my campaign only has 2 items and they are both obviously fine, I get flagged? This made me feel like I am being watched and timed.

- "In a SOX or regulatory audit, you may be interviewed about specific approvals." -- This is the sentence that scared me the most. I am a call center manager. I do not want to be interviewed by auditors. The guide makes it sound like every click I make could end up in a deposition.

### The Rubber-Stamping Section Feels Accusatory

Section 9 is titled "Avoiding Rubber-Stamping" and it leads with a table showing how my behavior will be *detected* and what it *suggests*. I have not even completed my first review yet, and the guide is already telling me what I might do wrong and how I will be caught. This feels like a warning from a parole officer, not a helpful guide for a first-time user.

The "Critical" callout at the end of Section 9 says my decisions are my "personal attestation" and I could be "interviewed about specific approvals." This is the compliance equivalent of reading someone their Miranda rights before they have done anything.

### Consequence Clarity

I actually do not know what happens if I make a mistake. The guide says revocation is "generally permanent" -- what does "generally" mean? Are there exceptions? What are they? If I accidentally revoke someone's CRM access and they cannot take calls for the rest of the day, what is the recovery process and how long does it take? This is a real-world consequence that matters to me, and the guide does not address it.

The guide also never says what happens to *me* if an auditor questions my decisions. Am I disciplined? Is my name in a report? Does my boss get notified? The vague threat of "audit exposure" is actually scarier than a specific, defined consequence would be.

---

## What's Missing for Non-Technical Managers

**Rating: 1/5** (this is where the biggest gaps are)

### A "Quick Start" Section Is Essential

Yes, a "Quick Start: Complete Your First Campaign in 5 Minutes" section at the very top would be transformative. Something like:

1. You received an email saying you have a campaign to review. Click the link in the email.
2. You will see a list of your team members who received new access. For each person, you will see what access they got.
3. For each item, click the green checkmark to keep their access, or the red X to remove it.
4. When you have made a decision on every item, click Sign Off.
5. You are done.

That is what I need. Everything else is context for *why* I am doing this, which is important but secondary to *how*.

### Screenshots Are Not Optional -- They Are Critical

The single biggest improvement this guide could make is adding annotated screenshots showing:
- What the login page looks like
- What a campaign card looks like in the list
- What the Identities view looks like with a person expanded
- What the Approve/Revoke/Reassign buttons look like
- What the Sign-Off screen looks like
- What the "Acknowledge" button looks like vs. "Approve" (since the guide specifically distinguishes these)

Without screenshots, I am navigating blind. This is like giving someone driving directions using only street names with no map.

### Step-by-Step Numbered Instructions With Exact Button Names

The guide uses a mix of prose and numbered lists. The numbered lists are better, but they still lack the specificity I need. "Navigate to Certifications from the main menu" -- is that a left sidebar? A top menu bar? A hamburger menu? Is it literally the word "Certifications" or is it an icon?

### A Visual Decision Tree Would Be Extremely Helpful

The checklist in Section 12 is good conceptually, but a visual flowchart would be much easier to use in the moment:

```
Is this person still on your team?
  NO -> Reassign to their current manager
  YES -> Do you recognize this access / system?
    NO -> Reassign to someone who knows the system
    YES -> Does this person still use this access for their current job?
      NO -> Revoke
      YES -> Approve (add a brief comment explaining why)
```

That decision tree would replace several pages of text.

### A Help Contact Is Critical

The guide references "the IAM team" at least 8 times but never says who they are, how to contact them, or what their response time is. For a panicking non-technical manager, the single most valuable thing in this guide would be: "If you are stuck or unsure, email iam-support@company.com or call ext. 4500. Average response time: 2 hours."

### A Video Walkthrough

For a document like this, a 3-minute screen recording of someone completing a simple campaign would be worth more than the entire 13-section guide. Even a link that says "Watch a 3-minute walkthrough" would dramatically reduce anxiety.

---

## Scenarios

**Rating: 3/5**

### Most Relatable Scenarios

**Scenario 5 (Access You Cannot Evaluate)** is the most relatable to my situation by far. I would absolutely receive items I do not recognize and have no way to evaluate. The advice to reassign rather than guess is genuinely helpful and reassuring.

**Scenario 4 (Legitimate Privileged Access)** is also helpful because it shows that approving things is okay -- the guide spends so much time warning about rubber-stamping that I needed reassurance that approving is sometimes the right answer.

### Missing Scenarios That Would Be More Relevant

The current scenarios are all IT-flavored (Domain Admin, Exchange Admin, SCCM, DBA). None of them match my reality. I need scenarios like:

**"My team member just needs CRM access and I see a bunch of stuff I don't recognize."**
This is my most likely real-world situation. I know my team uses the CRM, the phone system, and Teams. If I see a campaign with 5 items and I only recognize 1 of them, what do I do? Approve the one I recognize and reassign the rest? Approve everything because I trust my team? The guide does not address partial knowledge.

**"I'm a new manager and inherited a team -- now what?"**
I just got promoted to manage a team that has been running for years. I get my first campaign and I see access for 15 people across systems I have never heard of. The guide says I should evaluate each item against "current job responsibilities," but I barely know what my team does yet. What is my move?

**"I don't know what half these systems even are."**
The scenarios assume I know what "Domain Admin" and "Exchange Admin" are. I do not. My team uses a CRM, a phone system, maybe some scheduling software. If I see "AD_CRMUsers_Tier2" in my campaign, is that the CRM? Or is it something else entirely? How do I find out?

**"Nothing looks wrong but I'm not sure."**
The scenarios all have clear right answers. In my real life, most things would be ambiguous. My team member has access that I *think* is fine but I am not *sure*. What do I do? The guide's implied answer is "ask the IAM team," but if every uncertain item requires an email to IAM, I will be sending 10 emails per campaign.

**"I accidentally revoked something and my team member can't do their job."**
This is my nightmare scenario and it is not covered. What is the emergency recovery process? How fast can access be restored?

---

## Document Format

**Rating: 3/5 (linear) / 4/5 (tabbed)**

### Linear vs. Tabbed

I strongly prefer the tabbed version. The linear version felt like reading a textbook from cover to cover when all I needed was Chapter 5. The tabbed version lets me go directly to "Decisions" or "FAQ" without scrolling through pages of context I can come back to later.

The welcome page on the tabbed version with the clickable cards is the closest thing in either document to a "start here" experience. The grouping of "Sections 5-7: Using the Interface" is exactly how I would navigate -- I want to see the practical how-to sections first.

The linear version is better for printing and for a first complete read-through. But for day-to-day reference (which is how I would actually use this), the tabbed version wins.

### Length

The document is too long for a first-time user who needs to complete a campaign today. I would not read all 13 sections before my first review. I would skip directly to Section 5, skim it, panic because there are no screenshots, then call someone.

Sections 1-4 are "why" content. They are important for buy-in but they should not come before the "how" content. A panicking manager will not read three sections of justification before learning what buttons to click.

Section 9 (Rubber-Stamping) and Section 10 (Least Privilege) are philosophical. They are valuable for training but not for task completion. They could be an appendix or a separate document.

### Would a 1-Page Cheat Sheet Help?

Absolutely. A single-page quick reference card with:
- Where to log in
- What a campaign looks like
- The three buttons and what they do
- The decision flowchart
- Who to call for help

That card taped to my monitor would be more useful than a 13-section guide saved in a SharePoint folder I will forget exists.

---

## Emotional Journey

**Rating: 2/5**

### Supported vs. Compliance Mandate

This guide feels like a compliance mandate wrapped in slightly friendlier language. The structure is: here is why this matters (compliance/audit/risk), here is what you need to do (review access), here is what happens if you do it wrong (audit scrutiny, rubber-stamping detection, personal accountability). The emotional arc is: anxiety -> obligation -> fear of mistakes.

A supportive guide would feel more like: you got this email and you are not sure what to do -- that is totally normal. Here is what this is about in plain English. Here are the exact steps. Here is who to call if you get stuck. You are not going to break anything.

### Empathy for How Busy and Confused I Am

There is almost no acknowledgment that this is a new, unfamiliar, and potentially anxiety-inducing process for non-IT managers. The guide assumes a baseline level of comfort with IT systems and identity governance concepts that a call center manager simply does not have.

The closest the guide gets to empathy is the "Tip" callout in Section 1: "Daily reviews are smaller than quarterly reviews, not more work." That is reassuring, but it is a single sentence buried after a paragraph about "blast radius."

### Tone Suggestions

- **Open with empathy.** "If this is your first time receiving an access certification email, you are not alone. Many managers outside of IT find this process unfamiliar. This guide will walk you through exactly what to do."

- **Normalize confusion.** "You may see access items with names like 'CN=AppUsers_Tier2' that mean nothing to you. That is completely normal. When you see something you do not recognize, you can reassign it to someone who does."

- **Reduce the threat level.** Instead of "Auditors review certification decisions... your decisions will be flagged," try: "The system tracks your decisions for compliance purposes. Taking a few seconds to review each item and add a brief note is all you need to do."

- **Lead with safety.** "You cannot break anything by reviewing access. If you accidentally approve or revoke something, you can change your mind before you finalize your review. After you finalize, the IT team can help fix mistakes."

- **Acknowledge the time burden.** "We know you are busy running your team. Most campaigns take 5-10 minutes. Think of it as a quick daily check, like reviewing your team's timesheets."

---

## Summary Ratings

| Area | Rating | Notes |
|---|---|---|
| First Impressions | 2/5 | Title and opening are intimidating; jargon-heavy subtitle |
| Can I Do My Job With This? | 2/5 | Missing login details, screenshots, and procedural specifics |
| Language and Jargon | 2/5 | Extensive jargon; glossary defines jargon with more jargon |
| Warnings and Fear Factor | 2/5 | Warnings are disproportionate; rubber-stamping section feels accusatory |
| Missing Content for Non-Technical Managers | 1/5 | No screenshots, no quick start, no help contact, no decision tree |
| Scenarios | 3/5 | Good concept but IT-focused; needs non-IT manager scenarios |
| Document Format | 3.5/5 | Tabbed version is better; both versions front-load "why" over "how" |
| Emotional Journey | 2/5 | Feels like compliance mandate, not supportive guide |

**Overall Score: 2.2 / 5**

---

## Top 5 Recommendations (Priority Order)

1. **Add a "Quick Start: Complete Your First Campaign" section as the very first thing in the document.** Five numbered steps. No jargon. Include the login URL placeholder and who to contact for credentials.

2. **Add annotated screenshots of every screen the reviewer will encounter.** Campaign list, campaign detail with identities expanded, the approve/revoke/reassign buttons, the sign-off page. This alone would move the rating from 2 to 4.

3. **Add a visual decision flowchart.** A simple yes/no tree that a manager can follow without reading the rest of the guide. Print-friendly, suitable for taping to a monitor.

4. **Rewrite the opening sections to lead with empathy and action, not compliance justification.** Move Sections 1-4 after Section 7, or make them an appendix. A panicking manager needs "what do I click" before "why this matters."

5. **Add a "Help and Support" section with actual contact information.** Name, email, phone number, or Teams channel for the IAM team. Expected response time. What to do if you accidentally revoke something critical.

---

*This review was written from the perspective of a call center manager with no identity governance experience. The guide is clearly well-researched and technically accurate. The problem is not the content -- it is the audience calibration. The guide is written for someone who already understands 60% of the concepts and needs the remaining 40%. A non-technical manager understands approximately 10% and needs the remaining 90%, starting with "what do I click."*
