from pathlib import Path
import json,os,sys,subprocess,secrets,tempfile,re,shlex
W=Path(__file__).resolve().parent/'results';B=Path('/Users/jerkerdelsing/Work/lule/EISLAB/Project/Eclipse');S=B/'roadmap/5.3/Arrowhead SoS architecture/SoS_tests';D=B/'OLD/Arrowhead/Arrowhead-test-cloud-java';sys.path.insert(0,str(S));from sos_tests.harness import HTTPS
p=json.loads((S/'config/profile.example.json').read_text());p['systems']=[s['name'] for s in json.loads((S/'catalog.json').read_text())['systems']];p['endpoints']={'registry':'https://127.0.0.1:8443','authentication':'https://127.0.0.1:8444','authorization':'https://127.0.0.1:8445'};x=D/'security/x509';p['ca']=str(x/'ca.crt');p['actors']={'inspector':{'cert':str(x/'sysop.crt'),'key':str(x/'sysop.key'),'token_env':'SOS_INSPECTOR_TOKEN'}};p['actors']['operator']=p['actors']['inspector']
def login(name,actor,password,env):
 q=dict(p);q['actors']={actor:{k:v for k,v in p['actors'][actor].items() if k!='token_env'}};r=HTTPS(q,W).request({'endpoint':'authentication','actor':actor,'path':'/authentication/identity/login','method':'POST','body':{'systemName':name,'credentials':{'password':password}}},{})
 if r['status']!=200 or not r['body'].get('token'):raise RuntimeError('Login failed for test actor, status '+str(r['status']))
 os.environ[env]=r['body']['token']
sysopPassword=next(shlex.split(line.split('=',1)[1],comments=True)[0] for line in (D/'.env').read_text().splitlines() if line.startswith('ARROWHEAD_SYSOP_PASSWORD='))
login('Sysop','inspector',sysopPassword,'SOS_INSPECTOR_TOKEN')
ca=D/'security/bundles/certificate-authority';suffix=subprocess.check_output(['openssl','x509','-in',str(ca/'ca.crt'),'-noout','-subject','-nameopt','RFC2253'],text=True);suffix=re.search(r'CN=([^,]+)',suffix).group(1);tmp=Path(tempfile.mkdtemp(prefix='sos-java-clients-'));names=[];passwords={};created=False
for role,label,env in [('provider','Provider','SOS_PROVIDER_TOKEN'),('consumer','Consumer','SOS_CONSUMER_TOKEN'),('other','Other','SOS_OTHER_TOKEN'),('loginConsumer','Login','SOS_LOGIN_TOKEN')]:
 name='SoSTest'+label+secrets.token_hex(4);names.append(name);passwords[name]=secrets.token_urlsafe(32);key=tmp/(role+'.key');csr=tmp/(role+'.csr');cert=tmp/(role+'.crt');ext=tmp/(role+'.ext');ext.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n')
 for cmd in [['openssl','req','-new','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(csr),'-subj','/CN='+name+'.'+suffix+'/dnQualifier=sy'],['openssl','x509','-req','-in',str(csr),'-CA',str(ca/'ca.crt'),'-CAkey',str(ca/'ca.key'),'-set_serial','0x'+secrets.token_hex(16),'-days','1','-extfile',str(ext),'-out',str(cert)]]:subprocess.run(cmd,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 key.chmod(0o600);p['actors'][role]={'cert':str(cert),'key':str(key),'token_env':env}
try:
 r=HTTPS(p,W).request({'endpoint':'authentication','actor':'operator','path':'/authentication/mgmt/identities','method':'POST','body':{'authenticationMethod':'PASSWORD','identities':[{'systemName':n,'credentials':{'password':passwords[n]},'sysop':False} for n in names]}},{})
 if r['status']!=201:raise RuntimeError('Isolated identity creation failed with status '+str(r['status']))
 created=True
 for role,name,env in zip(['provider','consumer','other'],names,['SOS_PROVIDER_TOKEN','SOS_CONSUMER_TOKEN','SOS_OTHER_TOKEN']):login(name,role,passwords[name],env)
 p['actors']['loginConsumer'].pop('token_env',None);p['variables']=dict(zip(['provider','consumer','otherConsumer','loginConsumer'],names));os.environ['SOS_CONSUMER_PASSWORD']=passwords[names[3]]
 p['scenarios']['AUTHZ-wrong-provider']['request']['actor']='consumer'
 for case in ['AUTHN-login','AUTHN-wrong-password']:
  for key in ['request','control']:
   if key in p['scenarios'][case]:p['scenarios'][case][key]['body']['systemName']='${loginConsumer}'
 r=HTTPS(p,W).request({'endpoint':'authorization','actor':'provider','path':'/consumerauthorization/authorization/verify','method':'POST','body':{'provider':names[0],'consumer':names[1],'cloud':'LOCAL','targetType':'SERVICE_DEF','target':'sosTestNoPolicy','scope':'read'}},{})
 print('Verification diagnostic',r['status'],r['body'])
 f=W/'sos-profile.json';f.write_text(json.dumps(p,indent=2));f.chmod(0o600)
 with (W/'sos-deployment-checks.log').open('w') as log:r=subprocess.run([sys.executable,str(S/'run_live.py'),'--profile',str(f),'--allow-mutations','--report',str(W/'sos-deployment-results.json')],stdout=log,stderr=subprocess.STDOUT,env=os.environ.copy())
 print('Isolated Java checks return code',r.returncode)
finally:
 if created:
  response=HTTPS(p,W).request({'endpoint':'authentication','actor':'operator','path':'/authentication/mgmt/identities','method':'DELETE','query':{'names':names}},{})
  (W/'sos-test-cleanup.json').write_text(json.dumps({'identityRemovalStatus':response['status'],'createdTestIdentities':len(names)})+'\n')
 for k in tmp.glob('*.key'):k.unlink()
