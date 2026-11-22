import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

// Real HTTP/WS through Host's bridge, not direct handler calls or mocked credentials.
export async function runBridgeRouteContract({ base, cookie, rpc, out, fixture, ownedSessionId }) {
  const directory = join(out, 'bridge-routes'); await mkdir(directory, { recursive: false });
  const result = { status: 'RUNNING', rows: [], startedUTC: new Date().toISOString(), scope: 'All fixed Dart route templates on a private Host runtime; runtime-capabilities belongs to OH; no device media playback or system chooser claim' };
  const persist = () => writeFile(join(directory, 'report.json'), JSON.stringify(result, null, 2) + '\n');
  const check = (condition, message) => assert.ok(condition, message);
  const jsonCode = body => body?.error?.code ?? body?.code ?? null;
  async function request(id, method, path, { body, raw, anonymous = false, headers = {} } = {}) {
    const data = raw ?? (body === undefined ? undefined : Buffer.from(JSON.stringify(body)));
    const row = { id, method, path, authentication: anonymous ? 'none' : 'real-launch-cookie', startUTC: new Date().toISOString(), ...(body === undefined ? {} : { requestBody: body }) };
    if (data) row.requestBytes = { bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') };
    result.rows.push(row);
    try {
      const response = await new Promise((resolve, reject) => {
        const req = http.request(new URL(path, base), { method, headers: { ...(anonymous ? {} : { Cookie: cookie }), ...(data ? { 'content-type': raw ? 'application/octet-stream' : 'application/json', 'content-length': data.length } : {}), ...headers } }, res => {
          const chunks = []; let size = 0;
          res.on('data', bytes => { size += bytes.length; if (size > 2 * 1024 * 1024) res.destroy(new Error('contract response limit')); else chunks.push(bytes); });
          res.on('error', reject); res.on('end', () => resolve({ status: res.statusCode, headers: Object.fromEntries(Object.entries(res.headers).filter(([key]) => key.toLowerCase() !== 'set-cookie')), raw: Buffer.concat(chunks) }));
        });
        req.on('error', reject); req.setTimeout(15000, () => req.destroy(new Error(`contract timeout ${id}`))); req.end(data);
      });
      const filename = `${String(result.rows.length).padStart(2, '0')}-${id}.bin`;
      await writeFile(join(directory, filename), response.raw);
      row.response = { status: response.status, headers: response.headers, bytes: response.raw.length, sha256: createHash('sha256').update(response.raw).digest('hex'), file: filename };
      try { response.json = JSON.parse(response.raw.toString('utf8')); row.response.json = response.json; row.response.errorCode = jsonCode(response.json); } catch { row.response.text = response.raw.toString('utf8'); }
      row.endUTC = new Date().toISOString(); await persist(); return response;
    } catch (error) { row.error = { name: error.name, message: error.message }; row.endUTC = new Date().toISOString(); await persist(); throw error; }
  }
  // This is the production session API over authenticated HTTP, not a fixture handler.
  // OH has no image codec: valid content must reach the explicit codec refusal.
  const attachments = { status: 'RUNNING', cases: [], scope: 'owner full-reference HTTP; no reader authorization or OH codec-success claim' };
  result.attachments = attachments;
  async function attachmentCase(id, sessionId, reference, code, reason, { legacy = false, anonymous = false } = {}) {
    const rpcId = randomUUID();
    const body = { type: 'client-request', rpcId, method: 'session/attachment', payload: { args: {
      request: legacy ? { sessionId, attachmentId: reference.attachmentId } : { sessionId, attachment: reference },
    } } };
    const response = await request('attachment-' + id, 'POST', '/api/session/attachment', { body, anonymous });
    const row = { id, sessionId, expectedCode: code, expectedReason: reason ?? null, passed: false };
    attachments.cases.push(row);
    if (anonymous) {
      check([401, 403].includes(response.status), 'anonymous attachment must be rejected by real authentication');
    } else {
      check(response.status === 200, 'attachment RPC uses the real HTTP result envelope: ' + id);
      check(response.json?.type === 'server-response' && response.json.rpcId === rpcId, 'attachment RPC identity: ' + id);
      const failure = response.json.result;
      check(failure?.ok === false && failure.error?.code === code, 'attachment error code: ' + id);
      if (reason !== undefined) check(failure.error.details?.reason === reason, 'attachment error reason: ' + id);
      row.actualCode = failure.error.code;
      row.actualReason = failure.error.details?.reason ?? null;
    }
    row.passed = true; await persist();
  }
  try {
    const cap = await request('runtime-capabilities', 'GET', '/dsh-go/v1/runtime-capabilities');
    check(cap.status === 200 && cap.json?.v === 1 && cap.json.platform === 'openharmony' && cap.json.nodeVersion === '24.22.1', 'OH authenticated capability contract');
    const inventory = await request('inventory', 'GET', '/dsh-go/v1/inventory');
    check(inventory.status === 200 && inventory.json?.v === 1 && typeof inventory.json.bridge === 'string' && inventory.json.routeGuard === true, 'bridge inventory and its real loopback routeGuard');
    const anon = await request('inventory-anonymous', 'GET', '/dsh-go/v1/inventory', { anonymous: true });
    check([401, 403].includes(anon.status), 'anonymous inventory must be guarded');
    const canary = await request('guard-canary-authenticated', 'GET', '/dsh-go-guard-canary'); check(canary.status === 204, 'actual canary registered');
    const canaryAnon = await request('guard-canary-anonymous', 'GET', '/dsh-go-guard-canary', { anonymous: true }); check([401, 403].includes(canaryAnon.status), 'anonymous canary guarded');

    const listing = await request('plugin-config-list', 'GET', '/dsh-go/v1/plugin-config');
    check(listing.status === 200 && Array.isArray(listing.json?.entries), 'plugin-config list');
    check(listing.json.entries.some(entry => entry.entryId === fixture.entryId && entry.configurable && entry.writable && entry.owner === 'installed' && entry.bundle === 'dsh-go-fixture-host-config-bundle'), 'declared installed fixture is configurable and writable');
    const entryPath = `/dsh-go/v1/plugin-config/${encodeURIComponent(fixture.entryId)}`;
    const config = await request('plugin-config-read', 'GET', entryPath); check(config.status === 200 && config.json?.value?.label === 'initial-label' && typeof config.json.revision === 'string', 'read real fixture config');
    const changed = await request('plugin-config-write', 'POST', entryPath, { body: { revision: config.json.revision, ops: [{ op: 'set', path: ['label'], value: 'changed-label' }] } });
    check(changed.status === 200 && changed.json?.value?.label === 'changed-label', 'write real fixture config');
    const reread = await request('plugin-config-reread', 'GET', entryPath); check(reread.status === 200 && reread.json?.value?.label === 'changed-label', 'configuration readback');

    const deletion = await request('session-deletion-capability', 'GET', '/dsh-go/v1/sessions/deletion');
    check(deletion.status === 200 && deletion.json?.version === 1 && deletion.json.supported === true, 'safe deletion seam available');
    const sessionId = ownedSessionId; check(typeof sessionId === 'string' && sessionId.length > 0, 'completed private session supplied'); result.disposableSession = sessionId;
    const listedBefore = await rpc('session/list', { _request: {} });
    result.sessionListBefore = listedBefore; check(Array.isArray(listedBefore.items) && listedBefore.items.some(item => item.sessionId === sessionId), 'completed private session really listed before deletion');
    const image = fixture.attachments.reference;
    check(image.attachmentId === 'sha256:' + fixture.assetSHA256 && image.bytes === fixture.assetBytes && image.width === 1 && image.height === 1, 'fixed real PNG full reference');
    await attachmentCase('full-reference', sessionId, image, 'session/attachment-invalid', 'OHOS_IMAGE_CODEC_UNAVAILABLE');
    await attachmentCase('missing-object', sessionId, { ...image, attachmentId: fixture.attachments.missingId }, 'session/attachment-invalid', 'ATTACHMENT_NOT_FOUND');
    await attachmentCase('corrupt-object', sessionId, { ...image, attachmentId: fixture.attachments.corruptId }, 'session/attachment-invalid', 'ATTACHMENT_CORRUPT');
    await attachmentCase('invalid-reference', sessionId, { ...image, attachmentId: 'not-an-attachment-id' }, 'session/attachment-invalid', 'INVALID_ATTACHMENT_REF');
    await attachmentCase('legacy-shape', sessionId, image, 'gateway/input-invalid', undefined, { legacy: true });
    await attachmentCase('anonymous', sessionId, image, null, undefined, { anonymous: true });
    const deleted = await request('session-delete', 'POST', '/dsh-go/v1/sessions/delete', { body: { sessionId } });
    check(deleted.status === 200 && deleted.json?.deleted === true && deleted.json.sessionId === sessionId, 'delete only owned disposable session');
    const listedAfter = await rpc('session/list', { _request: {} });
    result.sessionListAfter = listedAfter; check(Array.isArray(listedAfter.items) && !listedAfter.items.some(item => item.sessionId === sessionId), 'actual subsequent session absence');
    // sessionId is permission scope, not an image-history lookup. Owner bypasses
    // remoteAccess.decide; this is deliberately not a restricted-reader test.
    await attachmentCase('deleted-owner-session', sessionId, image, 'session/attachment-invalid', 'OHOS_IMAGE_CODEC_UNAVAILABLE');
    check(attachments.cases.length === 7 && attachments.cases.every(row => row.passed), 'all seven real attachment HTTP cases');
    attachments.status = 'PASS_OH_FULL_REFERENCE_CONTRACT';


    const occupancyPackage = 'dsh-go-fixture-host-bridge';
    const occupancyBody = { bootRev: 'add12-private-boot', slots: { 'composer.before': [{ package: occupancyPackage, cell: 'private-cell', active: true }] }, attribution: 'fixture', unresolved: 0 };
    const occupancy = await request('occupancy', 'POST', '/dsh-go/v1/occupancy', { body: occupancyBody }); check(occupancy.status === 204, 'browser-half occupancy write');
    const inventoryAfter = await request('inventory-after-occupancy', 'GET', '/dsh-go/v1/inventory'); check(inventoryAfter.status === 200 && inventoryAfter.json?.bootRev === occupancyBody.bootRev && inventoryAfter.json.slots?.['composer.before']?.[0]?.package === occupancyPackage, 'occupancy observed through inventory');
    result.status = 'PASS_HOST_BRIDGE_ROUTE_CONTRACT';
    result.templatesExercised = new Set(result.rows.map(row => `${row.method} ${row.path.replace(/[?#].*$/, '')}`)).size;
  } catch (error) { result.status = 'FAIL_HOST_BRIDGE_ROUTE_CONTRACT'; result.error = { name: error.name, message: error.message }; throw error; }
  finally {
    result.endedUTC = new Date().toISOString(); await persist();
  }
  return result;
}
