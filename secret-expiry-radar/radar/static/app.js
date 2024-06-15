'use strict';
const $ = id => document.getElementById(id);
const labels = {tls:'TLS certificate',api_key:'API key',aws_access_key:'AWS access key',azure_secret:'Azure credential',github_token:'GitHub token',ssh_key:'SSH key',dns_certificate:'DNS service certificate',oauth_credential:'OAuth credential'};
let assets = [], token = '', busy = false;
for (const [value, label] of Object.entries(labels)) {
  const option = document.createElement('option'); option.value=value; option.textContent=label; $('kind').append(option);
}
function cell(row, main, secondary) {
  const td=document.createElement('td'); td.textContent=main;
  if(secondary){const small=document.createElement('small');small.textContent=secondary;td.append(small);}
  row.append(td);return td;
}
function render() {
  const query=$('search').value.toLowerCase();
  const selected=assets.filter(a=>(`${a.name} ${a.owner} ${a.environment}`.toLowerCase().includes(query))&&($('status').value==='all'||a.status===$('status').value)&&($('kind').value==='all'||a.kind===$('kind').value));
  $('inventory').replaceChildren();
  for(const a of selected){
    const row=document.createElement('tr');
    cell(row,a.name,labels[a.kind]||a.kind);cell(row,a.owner,a.environment);
    cell(row,a.deadline?new Date(a.deadline).toISOString().slice(0,16).replace('T',' '):'Not recorded',a.basis==='rotation'?'Rotation policy':a.basis==='expiry'?'Actual expiry':'Review required');
    cell(row,a.days===null?'Unknown':a.days<0?`${Math.abs(a.days)}d overdue`:a.days===0?'Due now / overdue':`${a.days} days`);
    const td=cell(row,'');const badge=document.createElement('span');badge.className=`badge ${a.status}`;badge.textContent=a.status;td.append(badge);$('inventory').append(row);
  }
  $('count').textContent=`${selected.length} of ${assets.length} records`;$('empty').hidden=selected.length>0;
}
async function refresh(){
  if(busy)return;busy=true;$('refresh').disabled=true;
  try{
    const response=await fetch('/api/assets',{headers:token?{Authorization:`Bearer ${token}`}:{},signal:AbortSignal.timeout(10000)});
    if(!response.ok)throw new Error(response.status===401?'Enter your access token to load the inventory.':'Inventory unavailable. Try refreshing.');
    const data=await response.json();assets=data.assets;
    $('total').textContent=assets.length;$('critical').textContent=assets.filter(a=>['critical','overdue'].includes(a.status)).length;
    $('warning').textContent=assets.filter(a=>a.status==='warning').length;$('unknown').textContent=assets.filter(a=>a.status==='unknown').length;
    const demo=assets.some(a=>a.source==='synthetic');
    $('message').textContent=demo?'Demo inventory · Synthetic records for demonstration only.':'';
    $('updated').textContent=`Updated ${new Date().toISOString().slice(11,19)} UTC`;
    $('notifications').textContent=`${data.notifications} persisted dashboard notification deliveries (including prior deadlines).`;
    $('rundetails').replaceChildren();
    if(data.runs.length){const run=data.runs[0];$('run').textContent=`${run.summary.dry_run?'Dry run':'Delivery run'} · ${new Date(run.at).toISOString().slice(0,16).replace('T',' ')} UTC`;for(const key of ['due','sent','skipped','failed']){const span=document.createElement('span');span.textContent=`${run.summary[key]} ${key}`;$('rundetails').append(span);}}
    else{$('run').textContent='No checks recorded yet.';}
    render();
  }catch(error){$('message').textContent=error.message;$('updated').textContent='Refresh failed. Previously loaded records may be stale.';}
  finally{busy=false;$('refresh').disabled=false;}
}
$('connect').addEventListener('click',()=>{token=$('token').value;$('token').value='';refresh();});
$('token').addEventListener('keydown',event=>{if(event.key==='Enter')$('connect').click();});
$('refresh').addEventListener('click',refresh);
for(const id of ['search','status','kind'])$(id).addEventListener('input',render);
refresh();setInterval(refresh,60000);
