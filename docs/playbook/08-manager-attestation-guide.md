# Manager's Guide to Access Certification Reviews

> **Audience:** All people-managers who receive certification campaigns in SailPoint
> Identity Security Cloud (ISC). If this is your first time receiving an access review
> email, you are not alone. This guide walks you through exactly what to do -- step by
> step, in plain language. Most reviews take **5-10 minutes**. You cannot break anything
> while reviewing.
>
> **Need help?** Contact the IAM team: **[IAM-TEAM-EMAIL]** | **[IAM-TEAM-PHONE]**

---

## 1. Quick start: complete your review in 5 minutes

You got an email saying you have access to review. Here is exactly what to do.

> **Tip:** You cannot break anything while reviewing. Access is only affected after
> you click **Sign Off** at the very end. Until then, you can change any decision.

1. **Click the link in your email** -- or go to `[YOUR-ORG.identitynow.com]` and log in
   with your corporate credentials. You may need multi-factor authentication.
2. **You will see your team members who received new access.** Click on a person to see
   the details of what access they were given.
3. **For each item, click Approve or Revoke.** Approve (checkmark) means "yes, keep this
   access." Revoke (X) means "no, remove it." If you do not recognize the system, click
   **Reassign** to send it to someone who can evaluate it.
4. **Add a brief comment for important decisions.** A one-line note is enough: "Still
   working on Project X" or "Transferred teams, no longer needed."
5. **Click Sign Off when you have decided on every item.** Review your decisions on the
   summary page, then click **Finish**. Your decisions are now final. You are done.

---

## 2. Navigating the SailPoint interface

### Getting to your campaign

1. Click the link in your notification email, or go to `[YOUR-ORG.identitynow.com]`
2. Log in with your corporate credentials (multi-factor authentication may be required)
3. Click **Certifications** in the navigation menu
4. Select the **Active** tab -- this shows campaigns waiting for your review

### Campaign cards

Each campaign appears as a card showing: campaign name, number of items to review,
deadline, and progress. Click **Details** or **Review** to open it.

### Two ways to review: people vs. access

Inside a campaign, you can switch between two views:

| View | What you see | Best for |
|---|---|---|
| **Identities** (recommended) | Your team members -- click a person to see all their access | "Let me handle everything about Jane, then John" |
| **Access Items** | Permissions and access -- click one to see which team members have it | "Do all 5 people really need this same admin access?" |

### What you see for each item

| Information | What it means |
|---|---|
| **Privileged flag** | Elevated risk -- pay extra attention |
| **New access flag** | Recently added (this is why it appeared in your campaign) |
| **Last activity** | When the person last used this access -- months-old = question it |
| **Peer comparison** | Whether others in the same role have this access |
| **How it was granted** | Requested = you can approve or revoke. Auto-assigned = acknowledge only |

> **Tip:** If you see a "privileged" flag on access that has not been used in 60+ days,
> that is a strong signal to either revoke it or check with the team member.

---

## 3. Making decisions: approve, revoke, reassign

### Approve

Click the **checkmark icon**. This means "yes, this person should have this access."
Nothing changes -- the access stays in place and your approval is recorded.

> **Note:** Some items show **Acknowledge** instead of Approve. These are access items
> that were automatically assigned based on job title or department. You cannot remove
> them through this review -- contact the IAM team if the assignment seems wrong.

### Revoke

Click the **X icon**. This means "no, remove this access."

After you sign off:
- **Connected systems** (like Active Directory): access is removed automatically
- **Other systems** (apps without a direct connection): a task is created for the system
  owner to remove it manually

> **Tip:** Mistakes are fixable. Before sign-off, click **Revisit Decision** to change
> it. After sign-off, contact the IAM team at **[IAM-TEAM-EMAIL]** -- access can be
> re-requested through the standard process (typically takes **[X hours/days]**).

### Reassign

If you are not the right person to evaluate an item, send it to someone who is. Use
reassign when you do not recognize the system, the person recently transferred to you,
or you are going on leave.

**Rules:** You cannot reassign to the person being reviewed (no self-certification).
You cannot reassign after you have signed off.

> **Tip:** Reassigning is not a sign of failure -- it is the responsible thing to do
> when you lack context. Always better than guessing.

### Bulk decisions

Select multiple items with checkboxes and click **Bulk Decisions** to approve or revoke.
Use carefully for elevated access -- review those individually.

### Comments

Add a short note to any decision. Required for some revocations, recommended for
elevated access. One sentence is enough:
- "Employee transferred to Marketing June 1 -- no longer needs this"
- "Active DBA; still primary administrator for these servers"

### Decision flowchart: should I approve or revoke?

Follow this guide when unsure:

1. **Is this person still on your team?** No --> **Reassign** to their current manager
2. **Do you recognize this system?** No --> **Reassign** to the system owner, or ask the team member
3. **Does this person use this access for their current job?** No --> **Revoke** with comment
4. **Is there a lower-level access that would work?** Yes --> **Revoke** and request the alternative via IAM
5. None of the above --> **Approve** with a brief comment explaining why

### Checklist for elevated access

For items flagged as "privileged," run through this quick checklist:

- [ ] **Current role match:** Does this access fit their current job (not a previous role)?
- [ ] **Active use:** Have they used it recently, or has it been sitting idle?
- [ ] **Minimum needed:** Is this the least amount of access that works?
- [ ] **Time-bound?** Should this expire on a specific date?
- [ ] **Conflict check:** Does approving this create a conflict with other access they have?
- [ ] **Peer comparison:** Do others in the same role have this, or is this person an outlier?

---

## 4. Signing off and completing your review

When you have made decisions on all items:

1. The system shows a **summary page** with your decisions
2. Review carefully -- this is your last chance to change anything
3. Click **Finish** to submit

After sign-off:
- Your certification moves to the **Completed** tab
- Your decisions become **permanent** -- no further changes possible
- Approved items stay in place; revoked items begin removal
- Your decisions, timestamps, and comments are permanently recorded

### What if you miss the deadline?

An administrator handles undecided items (typically by keeping access in place).
Incomplete reviews are visible to compliance teams. Try to complete your review the
same day -- most take 5-10 minutes.

---

## 5. Common scenarios

### New hire with too much access

Alex has admin permissions from a broad onboarding template. **Revoke** the admin
access that does not match the role, **Approve** what fits. Comment: "New hire;
right-sizing to junior developer role."

### Team member transferred with old access

Jamie transferred from Infrastructure 3 months ago. **Approve** the new developer
tool, **Revoke** the 4 old infrastructure permissions. Comment: "Role transfer; no
longer needed."

### "I only use it during emergencies"

Chris has standing admin access used once a quarter. **Revoke** and work with the IAM
team to set up on-demand emergency access.

### Access that is clearly appropriate

DBA Pat actively manages three production servers. **Approve** with comment: "Active
DBA; primary administrator per current assignment." The goal is informed decisions,
not maximum revocations.

### Access you do not recognize

You see "SCCM_PatchAdmin_Tier2" -- a system you have never heard of. **Reassign** to
the system owner. Reassigning is always better than guessing.

### Your team only uses CRM, but you see unfamiliar items

**Approve** what you recognize (CRM, phone system). For unknown items, ask the team
member or **Reassign** to a technical lead.

### You are a new manager and inherited a team

Make decisions where you can. **Reassign** unfamiliar items to the previous manager or
team lead. Contact the IAM team -- they can help you understand your team's typical
access profile.

### You accidentally revoked something needed

Before sign-off: click **Revisit Decision**. After sign-off: contact the IAM team
immediately. Access can be re-requested (typically **[X hours/days]**). Mistakes are
fixable -- this is not a career-ending event.

---

## 6. Why we review access daily

Traditional access reviews happen quarterly -- a user gets elevated access on January 3
and the next review is April 1. For 88 days, that access sits unexamined.

**Daily delta reviews** change the equation: we review only access that changed in the
last 24 hours. Typically 1-5 items, taking 5-10 minutes. You only receive a campaign
when something changes. No changes = no campaign = no action needed.

| Approach | Scope per review | Reviewer fatigue | Time until review |
|---|---|---|---|
| **Quarterly full** | Hundreds of items | High (rubber-stamping risk) | Up to 90 days |
| **Daily delta** | 1-5 items (typical) | Low (focused decisions) | Less than 24 hours |

### Why elevated access gets extra attention

Standard access (email, CRM, HR self-service) poses relatively low risk. Elevated
access -- permissions that let someone administer servers, manage all user accounts,
or access sensitive data organization-wide -- is different:

| Risk factor | Standard access | Elevated access |
|---|---|---|
| **Impact if compromised** | One person's data | Entire organization |
| **Target for attackers** | Low priority | First thing attackers look for |
| **Compliance requirements** | Periodic review | Frequent review with documentation |
| **Recovery if breached** | Hours | Days to weeks |

---

## 7. Why managers review (not system admins)

System administrators know the system but not the people. Only you, as the manager, can
answer the critical question: "Should this person have this access for their current
role?"

You know:
- What your team member is working on right now
- Whether they recently changed roles or projects
- Whether the access was a temporary need that has expired
- Whether someone else could do the task with lower-level access

> **Note:** The system automatically sends each manager a review containing only their
> direct reports. You never see someone else's team.

---

## 8. Talking to your team about access

### Four questions to ask

1. **"What specifically do you need to accomplish?"** -- Understand the task, not the access.
2. **"Is there a way to do this with less access?"** -- Read-only instead of read-write?
3. **"How long will you need this?"** -- "For this project" means it should have an end date.
4. **"What happens if you lose this access tomorrow?"** -- "Nothing" = your signal to revoke.

### Setting the tone

Frame access reviews as **professional hygiene**, not punishment:

| Instead of... | Try... |
|---|---|
| "I'm revoking your access" | "Let's right-size your access to match your current role" |
| "Security says you can't have this" | "We're reducing the team's risk exposure" |
| "You don't need admin access" | "What specific tasks need admin? Let's find the right level" |

---

## 9. What good reviews look like

The goal is **informed, documented decisions** -- not maximum revocations.

| Good pattern | What it shows |
|---|---|
| Each item reviewed individually | You considered each decision on its merits |
| Brief comments on key decisions | Your reasoning is documented for compliance |
| Mix of approvals and revocations over time | You are genuinely evaluating |
| Completed before the deadline | Timely and responsible |

> **Note:** Your certification decisions are part of the organization's compliance
> record. Taking a moment to look at each item and adding a brief comment for
> non-obvious decisions is all it takes to demonstrate a thoughtful review. This
> protects both you and the company.

---

## 10. Frequently asked questions

**Q: How often will I receive reviews?**
Only when a direct report receives new elevated access. If your team's access is stable,
you may go days or weeks without one.

**Q: How long do I have?**
Check the deadline on the campaign card. Typically 24-72 hours. Try to complete it the
same day -- most take 5-10 minutes.

**Q: What if I make a mistake?**
Before sign-off: click **Revisit Decision**. After sign-off: contact the IAM team at
**[IAM-TEAM-EMAIL]**. Access can be re-requested. Mistakes are fixable.

**Q: My team member says they need access I revoked.**
They submit a new access request through the normal process. For urgent needs, the IAM
team can expedite.

**Q: I received a review for someone who no longer reports to me.**
Reassign it to their current manager with a note about the reporting change.

**Q: Why can I only Acknowledge some items?**
Items automatically assigned based on job title or department cannot be changed through
reviews. Contact the IAM team if the assignment seems wrong.

**Q: I see system names I don't recognize.**
Reassign to the system owner, or ask the team member if they use it.

**Q: What does the "privileged" flag mean?**
The IT team flagged this as elevated risk (server admin, database admin, etc.). Give
these items extra attention.

**Q: What is the difference between a role, an access profile, and an entitlement?**
- **Entitlement:** One permission (e.g., membership in "CRM_Users")
- **Access Profile:** A bundle from one system (e.g., "Standard CRM Access" = 3 permissions)
- **Role:** A business-level bundle across systems (e.g., "Customer Service Rep" = CRM + phone + KB)

Think of it as: permissions are individual ingredients, access profiles are recipes,
and roles are complete meals.

---

## 11. Glossary

| Term | Definition |
|---|---|
| **Access Profile** | A bundle of permissions from one system (e.g., "Standard CRM Access") |
| **Birthright Access** | Access automatically given based on job title/department -- cannot be changed through a review |
| **Campaign** | A review cycle with a deadline. You receive one when your team's access needs checking. |
| **Daily Delta Review** | A review of only access that changed in the last 24 hours. "Delta" means "change." |
| **Entitlement** | A single, specific permission in a system (e.g., membership in a group called "CRM_Users") |
| **IAM Team** | The Identity and Access Management team. Contact: **[IAM-TEAM-EMAIL]** |
| **Identity** | A person as represented in the access management system (SailPoint's word for "employee") |
| **Least Privilege** | Only the access needed for your current job -- like only having keys to rooms you actually use |
| **Privileged Access** | Elevated permissions (server admin, database admin, etc.). Higher risk = more scrutiny. |
| **Privilege Creep** | Gradual buildup of access over time, especially during role changes. Daily reviews prevent this. |
| **Role** | A business-level access bundle spanning multiple systems (e.g., "Customer Service Rep" = CRM + phone + KB) |
| **SOX / SOC 2** | Regulatory standards requiring documented access reviews. Your reviews are part of this evidence. |
| **Source** | A connected system (Active Directory, your CRM, HR system) from which permissions are imported. |
