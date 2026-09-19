// Mock ISC API for a LIVE V4g run: oauth token + campaigns + certifications +
// access-review-items. Two phases via phase file: 1 = day-1 only, 2 = both days.
const http = require("http");
const fs = require("fs");
const PHASE_FILE = process.env.V4G_PHASE_FILE || "/tmp/v4g-phase.txt";
const PORT = parseInt(process.env.V4G_MOCK_PORT || "8766", 10);

function phase() { try { return fs.readFileSync(PHASE_FILE, "utf8").trim(); } catch { return "1"; } }

function item(id, identity, access, decision, opts = {}) {
  return {
    id: `ari-${id}`,
    decision: decision,                       // "APPROVE" | "REVOKE" | null (pending)
    comments: opts.auto ? "idNowAutoApproved" : (opts.comment || ""),
    modified: opts.when || "2026-09-05T12:00:00Z",
    reviewedBy: decision ? { id: "rev-1", name: opts.reviewer || "Rita Reviewer", email: "rita@x.com" } : null,
    identitySummary: { id: `id-${identity.toLowerCase().replace(/ /g, "")}`, name: identity, completed: !!decision },
    access: { id: `ent-${access}`, name: access, type: "ENTITLEMENT", source: { id: "src-ad", name: "Corp AD" } },
  };
}

const campaigns = {
  "camp-d1": {
    id: "camp-d1", name: "Daily Attestation - 2026-09-05", status: "ACTIVE", type: "MANAGER",
    created: "2026-09-05T08:00:00Z", deadline: "2026-09-12T00:00:00Z",
    totalCertifications: 1, completedCertifications: 0,
  },
  "camp-d2": {
    id: "camp-d2", name: "Daily Attestation - 2026-09-06", status: "ACTIVE", type: "MANAGER",
    created: "2026-09-06T08:00:00Z", deadline: "2026-09-13T00:00:00Z",
    totalCertifications: 1, completedCertifications: 1,
  },
};

const certs = {
  "camp-d1": [{
    id: "cert-d1", name: "Manager Access Review cert-d1", campaign: { id: "camp-d1", name: campaigns["camp-d1"].name, type: "MANAGER" },
    reviewer: { id: "rev-1", name: "Rita Reviewer", email: "rita@x.com", type: "IDENTITY" },
    certifier: { id: "rev-1", name: "Rita Reviewer", email: "rita@x.com" },
    decisionsMade: 2, decisionsTotal: 3, identitiesTotal: 3, completed: false, signed: null,
    phase: "ACTIVE", due: "2026-09-12T00:00:00Z", created: "2026-09-05T08:00:00Z", modified: "2026-09-05T12:00:00Z",
  }],
  "camp-d2": [{
    id: "cert-d2", name: "Manager Access Review cert-d2", campaign: { id: "camp-d2", name: campaigns["camp-d2"].name, type: "MANAGER" },
    reviewer: { id: "rev-1", name: "Rita Reviewer", email: "rita@x.com", type: "IDENTITY" },
    certifier: { id: "rev-1", name: "Rita Reviewer", email: "rita@x.com" },
    decisionsMade: 3, decisionsTotal: 3, identitiesTotal: 3, completed: true, signed: "2026-09-06T15:00:00Z",
    phase: "SIGNED", due: "2026-09-13T00:00:00Z", created: "2026-09-06T08:00:00Z", modified: "2026-09-06T15:00:00Z",
  }],
};

const items = {
  // Day 1: Alice PENDING, Bob REVOKED, Cara APPROVED (first seen approved)
  "cert-d1": [
    item("a1", "Alice Alpha", "App_Alpha", null),
    item("b1", "Bob Bravo", "App_Bravo", "REVOKE", { when: "2026-09-05T11:00:00Z" }),
    item("c1", "Cara Charlie", "App_Charlie", "APPROVE", { when: "2026-09-05T10:00:00Z" }),
  ],
  // Day 2: Alice APPROVED (newly decided), Bob APPROVED (RE-APPROVED after revoke), Cara APPROVED
  "cert-d2": [
    item("a2", "Alice Alpha", "App_Alpha", "APPROVE", { when: "2026-09-06T10:30:00Z" }),
    item("b2", "Bob Bravo", "App_Bravo", "APPROVE", { when: "2026-09-06T11:15:00Z", reviewer: "Delegate Dan" }),
    item("c2", "Cara Charlie", "App_Charlie", "APPROVE", { when: "2026-09-06T09:45:00Z" }),
  ],
};

function pagedJson(res, arr, u) {
  const limit = parseInt(u.searchParams.get("limit") || "250", 10);
  const offset = parseInt(u.searchParams.get("offset") || "0", 10);
  res.setHeader("X-Total-Count", String(arr.length));
  res.end(JSON.stringify(arr.slice(offset, offset + limit)));
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const p = u.pathname.replace(/^\/v3/, "");
  res.setHeader("Content-Type", "application/json");
  const activeCamps = phase() === "2" ? Object.values(campaigns) : [campaigns["camp-d1"]];

  if (p === "/oauth/token") { res.end(JSON.stringify({ access_token: "mock-jwt", token_type: "bearer", expires_in: 3600 })); return; }

  if (p === "/campaigns") {
    let out = activeCamps;
    const f = u.searchParams.get("filters") || "";
    const m = f.match(/name\s+sw\s+"([^"]+)"/i);
    if (m) out = out.filter(c => c.name.toLowerCase().startsWith(m[1].toLowerCase()));
    pagedJson(res, out, u); return;
  }
  let m2 = p.match(/^\/campaigns\/([^/]+)$/);
  if (m2 && campaigns[m2[1]]) { res.end(JSON.stringify(campaigns[m2[1]])); return; }

  if (p === "/certifications") {
    const f = u.searchParams.get("filters") || "";
    const cm = f.match(/campaign\.id\s+eq\s+"([^"]+)"|campaignRef\.id\s+eq\s+"([^"]+)"/i);
    const cid = cm ? (cm[1] || cm[2]) : null;
    const out = cid ? (certs[cid] || []) : Object.values(certs).flat();
    pagedJson(res, out, u); return;
  }
  let m3 = p.match(/^\/certifications\/([^/]+)\/access-review-items$/);
  if (m3) { pagedJson(res, items[m3[1]] || [], u); return; }
  let m4 = p.match(/^\/certifications\/([^/]+)$/);
  if (m4) { const all = Object.values(certs).flat().find(c => c.id === m4[1]); if (all) { res.end(JSON.stringify(all)); return; } }

  console.log("MISS", req.method, u.pathname + u.search);
  res.statusCode = 404;
  res.end(JSON.stringify({ detailCode: "404", messages: [{ text: "not in mock: " + u.pathname }] }));
});
server.listen(PORT, "127.0.0.1", () => console.log("v4g mock ISC on " + PORT));
