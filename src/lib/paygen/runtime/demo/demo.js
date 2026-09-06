const $ = id => document.getElementById(id);
const operation = () => $('operation-id').value;
const show = (id, value) => { $(id).textContent = JSON.stringify(value, null, 2); };
async function request(path, options = {}) {
  const response = await fetch(path, options);
  return { http_status: response.status, body: await response.json() };
}
async function refreshEvidence() { show('evidence', await request('/evidence')); }
async function callback(valid) {
  const events = await request(`/events/${encodeURIComponent(operation())}`);
  const event = events.body.events?.at(-1);
  if (!event) return show('callback', events);
  const headers = {'Content-Type':'application/json'};
  if (valid) Object.assign(headers, Array.isArray(event.headers) ? Object.fromEntries(event.headers) : event.headers);
  show('callback', await request('/callbacks', {method:'POST', headers, body:event.raw_body}));
  await refreshEvidence();
}
document.querySelectorAll('button').forEach(button => button.addEventListener('click', async () => {
  try {
  const id = encodeURIComponent(operation());
  const action = button.dataset.action;
  if (action === 'evidence') return await refreshEvidence();
  if (action === 'callback-valid') return await callback(true);
  if (action === 'callback-invalid') return await callback(false);
  const paths = {create:'/operations', retry:`/operations/${id}/retry`, status:`/operations/${id}`, cancel:`/operations/${id}/cancel`};
  const options = action === 'status' ? {} : {method:'POST', headers:{'Content-Type':'application/json'}, body: action === 'create' ? JSON.stringify({...JSON.parse($('operation-json').value), id:operation()}) : '{}'};
  show('result', await request(paths[action], options)); await refreshEvidence();
  } catch (error) { show('result', {client_error: error.message}); }
}));
$('operation-id').value = `ui-${Date.now()}`;
Promise.all([request('/artifacts'), request('/sample')]).then(([artifacts, sample]) => {
  show('artifacts', artifacts);
  $('operation-json').value = JSON.stringify(sample.body, null, 2);
  const roles = artifacts.body.roles || [];
  document.querySelector('[data-action="cancel"]').disabled = !roles.includes('cancel');
  document.querySelector('[data-action="status"]').disabled = !roles.includes('status');
  const delegated = artifacts.body.callback_verification === 'provider_verification';
  $('scope').textContent = delegated ? 'Provider callback verification requires an external host hook; this offline demo rejects unverified PayPal events.' : 'Synthetic local contract only. A callback can represent progress or reversal, not necessarily settlement.';
  document.querySelector('[data-action="callback-valid"]').disabled = delegated || !roles.includes('callback');
}).catch(error => show('result', {client_error: error.message}));
refreshEvidence().catch(error => show('evidence', {client_error: error.message}));
