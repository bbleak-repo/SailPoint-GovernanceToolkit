// Minimal mock ISC API for Invoke-SPConfigInventory smoke tests.
// Implements offset/limit paging, one 403 endpoint, and 404s for the rest.
const http = require("http");

function gen(n, mk) { return Array.from({ length: n }, (_, i) => mk(i)); }

const data = {
  "/v3/sources": gen(3, i => ({ name: `Source-${i}`, type: "AD", connectorName: "active-directory", owner: i === 2 ? null : { name: "Ops Admin" }, authoritative: i === 0, healthy: i !== 2, status: i === 2 ? "SOURCE_STATE_ERROR" : "SOURCE_STATE_HEALTHY", created: "2026-01-01T00:00:00Z" })),
  "/v3/roles": gen(600, i => ({ name: `Role-${String(i).padStart(3, "0")}`, owner: { name: "Role Owner" }, enabled: true, requestable: i % 2 === 0, created: "2026-02-01T00:00:00Z" })),
  "/v3/campaigns": gen(2, i => ({ name: `Daily Attestation - 2026-09-0${i + 1}`, type: "MANAGER", status: i === 0 ? "ACTIVE" : "COMPLETED", created: "2026-09-01T00:00:00Z", deadline: "2026-09-02T00:00:00Z", totalCertifications: 30, completedCertifications: 12 })),
  "/beta/entitlements": gen(500, i => ({ name: `Ent-${i}`, source: { name: "AD" }, attribute: "memberOf", privileged: i % 10 === 0, requestable: i % 10 === 0, created: "2026-03-01T00:00:00Z" })),
  "/beta/workgroups": gen(2, i => ({ name: `GovGroup-${i}`, description: "governance", owner: { name: "Gov Lead" }, memberCount: 4, connectionCount: 1 })),
  "/v3/transforms": gen(5, i => ({ name: `Transform-${i}`, type: "upper", internal: false })),
  "/v3/public-identities-config": { attributes: [{ key: "email" }], modified: "2026-08-01T00:00:00Z", modifiedBy: { name: "Admin" } },
};

const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const path = u.pathname;
  res.setHeader("Content-Type", "application/json");
  if (path === "/v3/search" && req.method === "POST") { res.setHeader("X-Total-Count", "1234"); res.end(JSON.stringify([{ name: "Sample Identity" }])); return; }
  if (path === "/v3/sod-policies") { res.statusCode = 403; res.end(JSON.stringify({ detailCode: "403 Forbidden" })); return; }
  if (path === "/v3/public-identities-config") { res.end(JSON.stringify(data[path])); return; }
  if (!(path in data)) { res.statusCode = 404; res.end(JSON.stringify({ detailCode: "404 Not Found" })); return; }
  const limit = parseInt(u.searchParams.get("limit") || "250", 10);
  const offset = parseInt(u.searchParams.get("offset") || "0", 10);
  res.end(JSON.stringify(data[path].slice(offset, offset + limit)));
});
server.listen(8765, "127.0.0.1", () => console.log("mock ISC on 8765"));
