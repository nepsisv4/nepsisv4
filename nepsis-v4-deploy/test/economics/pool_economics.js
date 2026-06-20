const solc=require('solc'),fs=require('fs');
const {VM}=require('@ethereumjs/vm');const {Common,Hardfork,Chain}=require('@ethereumjs/common');
const {Address,hexToBytes,bytesToHex}=require('@ethereumjs/util');const {ethers}=require('ethers');
const rd=p=>fs.readFileSync(p,'utf8');
const sources={'FixedPointMath.sol':{content:rd('FixedPointMath.sol')},'Nepsis.sol':{content:rd('Nepsis.sol')},'PatiencePool.sol':{content:rd('PatiencePool.sol')}};
function fi(p){const b=p.split('/').pop();return sources[b]?{contents:sources[b].content}:{error:'nf '+p}}
const out=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources,settings:{optimizer:{enabled:true,runs:200},evmVersion:'shanghai',outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}}),{import:fi}));
const errs=(out.errors||[]).filter(e=>e.severity==='error');if(errs.length){errs.forEach(e=>console.log(e.formattedMessage));process.exit(1)}
const G=(f,n)=>({abi:out.contracts[f][n].abi,bc:'0x'+out.contracts[f][n].evm.bytecode.object});
const Tok=G('Nepsis.sol','Nepsis'),Pool=G('PatiencePool.sol','PatiencePool');
const tokI=new ethers.Interface(Tok.abi),poolI=new ethers.Interface(Pool.abi);
const WAD=10n**18n,DAY=86400n,fmt=x=>(Number((x<0n?-x:x)*1000n/WAD)/1000*(x<0n?-1:1)).toString();
(async()=>{
  const vm=await VM.create({common:new Common({chain:Chain.Mainnet,hardfork:Hardfork.Shanghai})});
  let now=1000000n;
  const D=Address.fromString('0x00000000000000000000000000000000000000dd'),hook=Address.fromString('0x00000000000000000000000000000000000000ff');
  async function dep(bc){const r=await vm.evm.runCall({caller:D,origin:D,data:hexToBytes(bc),gasLimit:30000000n,block:{header:{timestamp:now}}});if(r.execResult.exceptionError)throw new Error('deploy '+JSON.stringify(r.execResult.exceptionError));return r.createdAddress.toString()}
  async function send(to,data,from,t){const r=await vm.evm.runCall({to:Address.fromString(to),caller:Address.fromString(from),origin:Address.fromString(from),data:hexToBytes(data),gasLimit:30000000n,block:{header:{timestamp:t||now}}});if(r.execResult.exceptionError)throw{revert:1,ret:bytesToHex(r.execResult.returnValue)};return bytesToHex(r.execResult.returnValue)}
  async function call(to,iface,fn,a=[],from=D.toString()){return iface.decodeFunctionResult(fn,await send(to,iface.encodeFunctionData(fn,a),from))}
  const nep=await dep(Tok.bc+tokI.encodeDeploy([1_000_000_000n*WAD,D.toString()]).slice(2));
  const pool=await dep(Pool.bc+poolI.encodeDeploy([nep]).slice(2));
  await send(pool,poolI.encodeFunctionData('setYieldSource',[hook.toString()]),D.toString());
  const A='0x'+'a'.repeat(40),B='0x'+'b'.repeat(40);
  for(const a of [A,B]){await send(nep,tokI.encodeFunctionData('transfer',[a,1_000_000n*WAD]),D.toString());await send(nep,tokI.encodeFunctionData('approve',[pool,10n**30n]),a)}
  await send(nep,tokI.encodeFunctionData('transfer',[hook.toString(),50_000_000n*WAD]),D.toString());
  const deposit=async(w,amt,lock)=>(await call(pool,poolI,'deposit',[amt,lock],w))[0];
  const yield_=async amt=>{await send(nep,tokI.encodeFunctionData('transfer',[pool,amt]),hook.toString());await send(pool,poolI.encodeFunctionData('receiveYield',[amt]),hook.toString())};
  // withdraw returns (principal, paidYield, forfeited) — decode it
  async function withdraw(w,id){const ret=await send(pool,poolI.encodeFunctionData('withdraw',[id]),w);const d=poolI.decodeFunctionResult('withdraw',ret);return{principal:d[0],paidYield:d[1],forfeited:d[2]}}

  console.log('=== Symmetric two-depositor test: identical deposits, one 1000 yield, ONLY difference is who exits first ===');
  const idA=await deposit(A,100_000n*WAD,3);
  const idB=await deposit(B,100_000n*WAD,3);
  now+=10n*DAY; await yield_(1000n*WAD);
  now+=21n*DAY; // both matured
  const wA=await withdraw(A,idA); // A exits first
  const wB=await withdraw(B,idB); // B exits second
  console.log(`  A (exits first):  principal=${fmt(wA.principal)}  paidYield=${fmt(wA.paidYield)}`);
  console.log(`  B (exits second): principal=${fmt(wB.principal)}  paidYield=${fmt(wB.paidYield)}`);
  console.log(`  fair split would be 500 / 500. Actual: ${fmt(wA.paidYield)} / ${fmt(wB.paidYield)}`);
  console.log(`  => first-mover took ${(Number(wA.paidYield*100n/(wA.paidYield+wB.paidYield||1n)))}% of the yield\n`);

  console.log('=== Sole-staker test: 1 depositor, 1000 yield delivered 1 day in, withdraw at half-maturity ===');
  const idA2=await deposit(A,100_000n*WAD,3);
  now+=1n*DAY; await yield_(1000n*WAD);
  now+=14n*DAY;
  const kf=(await call(pool,poolI,'previewForfeit',[A,idA2]))[0];
  const w2=await withdraw(A,idA2);
  console.log(`  delivered yield = 1000, sole staker, keepFrac(preview)=${fmt(kf)}`);
  console.log(`  EXPECTED kept ~= 0.75 * 1000 = 750.  ACTUAL paidYield = ${fmt(w2.paidYield)}, forfeited=${fmt(w2.forfeited)}`);
  console.log(`  (gross accrued before forfeiture, implied = paid+forfeited = ${fmt(w2.paidYield+w2.forfeited)} vs the 1000 actually delivered)`);
})().catch(e=>{console.log('ERR',e.revert?('revert '+e.ret):e);process.exit(1)});
