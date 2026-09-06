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
  if (valid) Object.assign(headers, Object.fromEntries(event.headers));
  show('callback', await request('/callbacks', {method:'POST', headers, body:event.raw_body}));
  await refreshEvidence();
}
document.querySelectorAll('button').forEach(button => button.addEventListener('click', async () => {
  const id = encodeURIComponent(operation());
  const action = button.dataset.action;
  if (action === 'evidence') return refreshEvidence();
  if (action === 'callback-valid') return callback(true);
  if (action === 'callback-invalid') return callback(false);
  const paths = {create:'/operations', retry:`/operations/${id}/retry`, status:`/operations/${id}`, cancel:`/operations/${id}/cancel`};
  const options = action === 'status' ? {} : {method:'POST', headers:{'Content-Type':'application/json'}, body: action === 'create' ? JSON.stringify({id:operation(),amount:'1500.00',currency:'RUB',payout_requisite:{sbp:{phone:'79990000001',bank_code:'000000000'}}}) : '{}'};
  show('result', await request(paths[action], options)); await refreshEvidence();
}));
$('operation-id').value = `ui-${Date.now()}`;
request('/artifacts').then(value => show('artifacts', value)); refreshEvidence();
