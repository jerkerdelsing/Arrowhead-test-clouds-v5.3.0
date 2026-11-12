#!/usr/bin/env python3
"""Delegate only the console editing operations; preserve all other policy scopes and clients."""
from pathlib import Path
import os,json,ssl,urllib.request,urllib.parse,subprocess,hashlib
root=Path.cwd();certs=Path(os.environ['CERT_DIR']);auth=os.environ['AUTHENTICATION_URL'];authz=os.environ['AUTHORIZATION_URL'];registry=os.environ['SERVICE_REGISTRY_URL']
ctx=ssl.create_default_context(cafile=str(certs/'ca.crt'));ctx.load_cert_chain(str(certs/'sysop.crt'),str(certs/'sysop.key'))
password=subprocess.check_output(['/bin/sh','-c','. ./scripts/lib-secrets.sh; secret ARROWHEAD_SYSOP_PASSWORD'],cwd=root,env=os.environ,text=True).strip()
def request(method,url,body=None,token=None):
 data=None if body is None else json.dumps(body).encode();headers={'Content-Type':'application/json'}
 if token:headers['Authorization']='Bearer IDENTITY-TOKEN//'+token
 req=urllib.request.Request(url,data=data,method=method,headers=headers)
 try:
  with urllib.request.urlopen(req,context=ctx,timeout=20)as response:
   raw=response.read();return json.loads(raw)if raw else None
 except urllib.error.HTTPError as e:
  detail=e.read().decode();raise RuntimeError(f'Authority returned HTTP {e.code}: {detail}')from None
login=request('POST',auth+'/authentication/identity/login',{'systemName':'Sysop','credentials':{'password':password}});token=login['token'];password=None
# Publish only the real manager certificate's public key after validating issuer, validity and revocation.
client=certs/'local-cloud-manager.crt';crl=Path(os.environ['CRL_FILE'])
subprocess.run(['/usr/bin/openssl','verify','-CAfile',str(certs/'ca.crt'),'-CRLfile',str(crl),'-crl_check',str(client)],check=True,capture_output=True)
subject=subprocess.check_output(['/usr/bin/openssl','x509','-in',str(client),'-noout','-subject'],text=True)
if 'CN=LocalCloudManager.'not in subject.replace(' ','')and'CN = LocalCloudManager.'not in subject:raise RuntimeError('Wrong manager certificate identity')
pem=subprocess.check_output(['/usr/bin/openssl','x509','-in',str(client),'-pubkey','-noout'])
spki=subprocess.check_output(['/usr/bin/openssl','pkey','-pubin','-outform','DER'],input=pem)
import base64
public=base64.b64encode(spki).decode()
systems=request('POST',registry+'/serviceregistry/mgmt/systems/query',{'systemNames':['LocalCloudManager']},token)
if systems.get('entries'):
 old=systems['entries'][0];metadata={**(old.get('metadata')or{}),'role':'local-cloud-monitor','managedProject':os.environ['COMPOSE_PROJECT_NAME'],'x509PublicKey':public,'consumerInterfaceTemplates':'generic_https'}
 if old.get('metadata')!=metadata:
  row={'name':'LocalCloudManager','metadata':metadata,'version':old.get('version')or'1.0.0','addresses':[a if isinstance(a,str)else a.get('address')or a.get('host')or a.get('value')for a in old.get('addresses',[])],'deviceName':old.get('deviceName')or(old.get('device')or{}).get('name')}
  request('PUT',registry+'/serviceregistry/mgmt/systems',{'systems':[row]},token);print('Published verified LocalCloudManager public key and HTTPS client capability')
scopes=[('ConsumerAuthorization','authorizationManagement',['query-policies','grant-policies','revoke-policies']),('SimpleStoreServiceOrchestration','serviceOrchestrationSimpleStoreManagement',['query','create','modify-priorities','remove'])]
base=authz+'/consumerauthorization/authorization/mgmt'
for provider,target,operations in scopes:
 response=request('POST',base+'/query',{'providers':[provider],'targetNames':[target],'targetType':'SERVICE_DEF','level':'MGMT','pagination':{'page':0,'size':1000}},token)
 rows=[p for p in response.get('entries',[])if p['provider']==provider and p['target']==target and(p.get('cloud')or'LOCAL')=='LOCAL'and p.get('level')=='MGMT']
 if len(rows)!=1:raise RuntimeError('Expected one existing LOCAL management policy for '+target)
 old=rows[0];policy=json.loads(json.dumps({k:old.get(k)for k in ['provider','targetType','target','description','defaultPolicy','scopedPolicies']}));policy['cloud']='LOCAL';policy['scopedPolicies']=policy.get('scopedPolicies')or{}
 original=json.dumps(policy,sort_keys=True)
 for operation in operations:
  source=policy['scopedPolicies'].get(operation)or policy.get('defaultPolicy')or{'policyType':'WHITELIST','policyList':['Sysop']};rule=json.loads(json.dumps(source));kind=rule['policyType'];names=rule.get('policyList')or[]
  if kind=='WHITELIST':rule['policyList']=sorted(set(names+['LocalCloudManager']))
  elif kind=='BLACKLIST':rule['policyList']=[n for n in names if n!='LocalCloudManager']
  elif kind!='ALL':raise RuntimeError('Unsupported existing policy type; no changes made')
  policy['scopedPolicies'][operation]=rule
 if json.dumps(policy,sort_keys=True)==original:print(target+': editing scopes already configured');continue
 # Official management API is revoke/grant. Restore the old configuration on grant failure.
 snapshot={k:old.get(k)for k in ['provider','targetType','target','description','defaultPolicy','scopedPolicies']};snapshot['cloud']='LOCAL'
 request('DELETE',base+'/revoke?instanceIds='+urllib.parse.quote(old['instanceId'],safe=''),token=token)
 try:result=request('POST',base+'/grant',{'list':[policy]},token)
 except Exception:
  request('POST',base+'/grant',{'list':[snapshot]},token);raise
 if not result.get('entries'):raise RuntimeError('Authority did not confirm the delegated policy')
 print(target+': delegated LOCAL console scopes '+', '.join(operations))
