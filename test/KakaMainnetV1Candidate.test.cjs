const assert=require('node:assert/strict');
const {ethers}=require('hardhat');

const PRICE=ethers.parseEther('0.01');
const HOUR=3600;

function salt(label){return ethers.keccak256(ethers.toUtf8Bytes(label));}
function digest(label){return ethers.keccak256(ethers.toUtf8Bytes(label));}
function packId(editionId,index){return (BigInt(editionId)<<64n)|BigInt(index);}
function pairHash(a,b){const [left,right]=BigInt(a)<BigInt(b)?[a,b]:[b,a];return ethers.keccak256(ethers.concat([left,right]));}
function merkleTree(leaves){
  const layers=[leaves];
  while(layers.at(-1).length>1){
    const current=layers.at(-1),next=[];
    for(let i=0;i<current.length;i+=2)next.push(pairHash(current[i],current[i+1]??current[i]));
    layers.push(next);
  }
  return {root:layers.at(-1)[0],proof(index){const proof=[];for(let level=0;level<layers.length-1;level++){const current=layers[level],sibling=index^1;proof.push(current[sibling]??current[index]);index=Math.floor(index/2);}return proof;}};
}

async function expectCustomError(action,name){
  try{const tx=await action;if(tx?.wait)await tx.wait();assert.fail(`Expected ${name}`);}
  catch(error){if(error.code==='ERR_ASSERTION')throw error;assert.match(String(error.shortMessage||error.message),new RegExp(name),String(error));}
}

async function deploy(){
  const [governance,risk,reviewer,publisher,buyer,relayer,other]=await ethers.getSigners();
  const Factory=await ethers.getContractFactory('KakaCollectionManagerV1');
  const manager=await Factory.deploy(governance.address,risk.address,reviewer.address);
  await manager.waitForDeployment();
  const cards=await ethers.getContractAt('KakaCardsV1',await manager.cards());
  const packs=await ethers.getContractAt('KakaPacksV1',await manager.packs());
  const market=await ethers.getContractAt('KakaMarketplaceV1',await manager.marketplace());
  return {manager,cards,packs,market,governance,risk,reviewer,publisher,buyer,relayer,other};
}

async function createEdition(manager,publisher,{key='v1-candidate',mode=3,specs,cardSupplies,terminalRares}){
  const editionId=await manager.nextEditionId();
  const leaves=[];
  for(let i=0;i<specs.length;i++)leaves.push(await manager.commitmentLeaf(editionId,i+1,specs[i].indexes,specs[i].amounts,specs[i].salt));
  const tree=merkleTree(leaves);
  const packSize=specs[0].amounts.reduce((sum,value)=>sum+value,0);
  const params={
    editionKey:digest(key),mode,packSize,packCount:specs.length,priceWei:PRICE,revealWindowSeconds:HOUR,
    contentRoot:tree.root,metadataDigest:digest(`${key}:metadata`),metadataURI:`ipfs://${key}/collection.json`,packURI:`ipfs://${key}/pack.json`,
    cardMetadataDigests:cardSupplies.map((_,i)=>digest(`${key}:card:${i}`)),
    cardURIs:cardSupplies.map((_,i)=>`ipfs://${key}/cards/${i}.json`),cardSupplies,terminalRares
  };
  await (await manager.connect(publisher).createEdition(params)).wait();
  return {editionId,tree,params};
}

async function signBurn(manager,signer,assetKind,tokenIds,deadline){
  const network=await ethers.provider.getNetwork();
  const nonce=await manager.burnNonce(signer.address);
  return signer.signTypedData(
    {name:'KAKA CARD MARKET',version:'1',chainId:network.chainId,verifyingContract:await manager.getAddress()},
    {BurnIntent:[
      {name:'owner',type:'address'},{name:'assetKind',type:'uint8'},{name:'tokenIds',type:'uint256[]'},
      {name:'nonce',type:'uint256'},{name:'deadline',type:'uint256'}
    ]},
    {owner:signer.address,assetKind,tokenIds,nonce,deadline}
  );
}

describe('KAKA mainnet-v1 candidate',function(){
  it('gates sales on human review and issues unique, never-reused card instance ids',async function(){
    const env=await deploy();
    const specs=[
      {indexes:[0,1],amounts:[1,1],salt:salt('review-1')},
      {indexes:[1],amounts:[2],salt:salt('review-2')}
    ];
    const created=await createEdition(env.manager,env.publisher,{specs,cardSupplies:[1,3],terminalRares:[false,false]});
    assert.equal((await env.manager.getEdition(created.editionId)).reviewStatus,1n);
    await expectCustomError(env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE}),'ReviewPending');
    await (await env.manager.connect(env.reviewer).reviewEdition(created.editionId,2,digest('human-approved'))).wait();
    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    const firstPack=packId(created.editionId,1);
    await (await env.manager.connect(env.buyer).requestOpen(firstPack)).wait();
    await (await env.manager.connect(env.relayer).revealPack(firstPack,{cardIndexes:specs[0].indexes,amounts:specs[0].amounts,salt:specs[0].salt,proof:created.tree.proof(0)})).wait();
    await expectCustomError(env.manager.connect(env.relayer).revealPack(firstPack,{cardIndexes:specs[0].indexes,amounts:specs[0].amounts,salt:specs[0].salt,proof:created.tree.proof(0)}),'PackAlreadyRevealed');
    assert.equal(await env.cards.ownerOf(1),env.buyer.address);
    assert.equal(await env.cards.ownerOf(2),env.buyer.address);
    const rare=await env.cards.cardInstance(1);
    const common=await env.cards.cardInstance(2);
    assert.equal(rare.editionId,created.editionId);
    assert.notEqual(rare.cardTypeId,common.cardTypeId);
    assert.equal(await env.cards.nextInstanceId(),3n);

    const deadline=BigInt((await ethers.provider.getBlock('latest')).timestamp+HOUR);
    const wrongSignature=await signBurn(env.manager,env.other,2,[1n,2n],deadline);
    await expectCustomError(env.manager.connect(env.relayer).executeBurn(env.buyer.address,2,[1n,2n],deadline,wrongSignature),'InvalidBurnSigner');
    const signature=await signBurn(env.manager,env.buyer,2,[1n,2n],deadline);
    await (await env.manager.connect(env.relayer).executeBurn(env.buyer.address,2,[1n,2n],deadline,signature)).wait();
    await expectCustomError(env.cards.ownerOf(1),'ERC721NonexistentToken');
    await expectCustomError(env.cards.ownerOf(2),'ERC721NonexistentToken');
    assert.equal(await env.cards.nextInstanceId(),3n);
    assert.equal((await env.manager.getCardType(created.editionId,0)).mintedSupply,1n);
    assert.equal((await env.manager.getCardType(created.editionId,1)).mintedSupply,1n);
    await expectCustomError(env.manager.connect(env.relayer).executeBurn(env.buyer.address,2,[1n,2n],deadline,signature),'InvalidBurnSigner');

    const rejected=await createEdition(env.manager,env.other,{key:'rejected',specs:[{indexes:[0],amounts:[1],salt:salt('reject-1')}],cardSupplies:[1],terminalRares:[false]});
    await (await env.manager.connect(env.reviewer).reviewEdition(rejected.editionId,3,digest('similarity-evidence'))).wait();
    const rejectedState=await env.manager.getEdition(rejected.editionId);
    assert.equal(rejectedState.reviewStatus,3n);
    assert.equal(rejectedState.saleClosed,true);
    await expectCustomError(env.manager.connect(env.buyer).buyPack(rejected.editionId,PRICE,{value:PRICE}),'ReviewPending');
  });

  it('routes a fixed five percent fee to governance on primary and secondary sales',async function(){
    const env=await deploy(),fee=PRICE*500n/10_000n,net=PRICE-fee;
    const created=await createEdition(env.manager,env.publisher,{key:'fees',specs:[{indexes:[0],amounts:[1],salt:salt('fee-1')}],cardSupplies:[1],terminalRares:[false]});
    await (await env.manager.connect(env.reviewer).reviewEdition(created.editionId,2,digest('fee-review'))).wait();
    const governanceBefore=await ethers.provider.getBalance(env.governance.address);
    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    assert.equal((await ethers.provider.getBalance(env.governance.address))-governanceBefore,fee);
    assert.equal((await env.manager.getEdition(created.editionId)).proceedsWei,net);

    const token=packId(created.editionId,1);
    await (await env.packs.connect(env.buyer).approve(await env.market.getAddress(),token)).wait();
    await (await env.market.connect(env.buyer).listPack(token,PRICE,0)).wait();
    const governanceBeforeSecondary=await ethers.provider.getBalance(env.governance.address);
    await (await env.market.connect(env.other).buy(1,PRICE,{value:PRICE})).wait();
    assert.equal((await ethers.provider.getBalance(env.governance.address))-governanceBeforeSecondary,fee);
    assert.equal(await env.market.sellerProceeds(env.buyer.address),net);
    assert.equal(await env.packs.ownerOf(token),env.other.address);
    assert.equal(await env.manager.PLATFORM_FEE_BPS(),500n);
    assert.equal(await env.market.PLATFORM_FEE_BPS(),500n);
    assert.equal(await env.manager.feeRecipient(),env.governance.address);
    assert.equal(await env.market.feeRecipient(),env.governance.address);
  });

  it('starts at the 1000 publisher, one collection and thirty face tier, then allows governance-only expansion',async function(){
    const env=await deploy();
    assert.equal(await env.manager.publisherLimit(),1_000n);
    assert.equal(await env.manager.editionLimitPerPublisher(),1n);
    assert.equal(await env.manager.cardTypeLimit(),30n);
    await createEdition(env.manager,env.publisher,{key:'publisher-first',specs:[{indexes:[0],amounts:[1],salt:salt('publisher-1')}],cardSupplies:[1],terminalRares:[false]});
    await expectCustomError(createEdition(env.manager,env.publisher,{key:'publisher-second',specs:[{indexes:[0],amounts:[1],salt:salt('publisher-2')}],cardSupplies:[1],terminalRares:[false]}),'PublisherEditionLimit');
    const supplies=Array(31).fill(1),indexes=supplies.map((_,index)=>index);
    await expectCustomError(createEdition(env.manager,env.other,{key:'too-many-faces',specs:[{indexes,amounts:supplies,salt:salt('faces-31')}],cardSupplies:supplies,terminalRares:supplies.map(()=>false)}),'TooManyCardTypes');
    await expectCustomError(env.manager.connect(env.other).increaseIssuanceLimits(2_000,2,60),'AccessControlUnauthorizedAccount');
    await expectCustomError(env.manager.connect(env.governance).increaseIssuanceLimits(999,2,60),'IssuanceLimitDecrease');
    await (await env.manager.connect(env.governance).increaseIssuanceLimits(2_000,2,60)).wait();
    assert.equal(await env.manager.publisherLimit(),2_000n);assert.equal(await env.manager.editionLimitPerPublisher(),2n);assert.equal(await env.manager.cardTypeLimit(),60n);
    await createEdition(env.manager,env.publisher,{key:'publisher-second-after-expansion',specs:[{indexes:[0],amounts:[1],salt:salt('publisher-3')}],cardSupplies:[1],terminalRares:[false]});
  });

  it('requires a signed burn intent, rejects locked packs, and records integer pack destruction',async function(){
    const env=await deploy();
    const specs=[
      {indexes:[0],amounts:[1],salt:salt('burn-1')},
      {indexes:[0],amounts:[1],salt:salt('burn-2')},
      {indexes:[0],amounts:[1],salt:salt('burn-3')}
    ];
    const created=await createEdition(env.manager,env.publisher,{key:'burn-packs',specs,cardSupplies:[3],terminalRares:[false]});
    await (await env.manager.connect(env.reviewer).reviewEdition(created.editionId,2,digest('review'))).wait();
    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    const first=packId(created.editionId,1);
    await (await env.manager.connect(env.buyer).requestOpen(first)).wait();
    let deadline=BigInt((await ethers.provider.getBlock('latest')).timestamp+HOUR);
    let signature=await signBurn(env.manager,env.buyer,1,[first],deadline);
    await expectCustomError(env.manager.connect(env.relayer).executeBurn(env.buyer.address,1,[first],deadline,signature),'LockedPackCannotBurn');

    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    const second=packId(created.editionId,2),third=packId(created.editionId,3);
    let expiredDeadline=BigInt((await ethers.provider.getBlock('latest')).timestamp+1);
    let expiredSignature=await signBurn(env.manager,env.buyer,1,[second,third],expiredDeadline);
    await ethers.provider.send('evm_increaseTime',[2]);await ethers.provider.send('evm_mine',[]);
    await expectCustomError(env.manager.connect(env.relayer).executeBurn(env.buyer.address,1,[second,third],expiredDeadline,expiredSignature),'BurnIntentExpired');
    deadline=BigInt((await ethers.provider.getBlock('latest')).timestamp+HOUR);
    signature=await signBurn(env.manager,env.buyer,1,[second,third],deadline);
    await (await env.manager.connect(env.relayer).executeBurn(env.buyer.address,1,[second,third],deadline,signature)).wait();
    await expectCustomError(env.packs.ownerOf(second),'ERC721NonexistentToken');
    await expectCustomError(env.packs.ownerOf(third),'ERC721NonexistentToken');
    assert.equal((await env.manager.getEdition(created.editionId)).destroyedPacks,2n);
  });

  it('lets risk staff pause new activity while preserving escrow cancellation and admin recovery',async function(){
    const env=await deploy();
    const specs=[{indexes:[0],amounts:[1],salt:salt('pause-1')},{indexes:[0],amounts:[1],salt:salt('pause-2')}];
    const created=await createEdition(env.manager,env.publisher,{key:'pause',specs,cardSupplies:[2],terminalRares:[false]});
    await (await env.manager.connect(env.reviewer).reviewEdition(created.editionId,2,digest('review'))).wait();
    await (await env.manager.connect(env.risk).suspendEdition(created.editionId,digest('edition-complaint'))).wait();
    await expectCustomError(env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE}),'ReviewPending');
    await (await env.manager.connect(env.governance).resumeEdition(created.editionId,digest('complaint-cleared'))).wait();
    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    const first=packId(created.editionId,1);
    await (await env.packs.connect(env.buyer).approve(await env.market.getAddress(),first)).wait();
    await (await env.market.connect(env.buyer).listPack(first,PRICE,0)).wait();

    await expectCustomError(env.manager.connect(env.risk).pauseProtocol(ethers.ZeroHash),'InvalidReasonDigest');
    await (await env.manager.connect(env.risk).pauseProtocol(digest('incident'))).wait();
    assert.equal(await env.market.marketPaused(),true);
    await expectCustomError(env.manager.connect(env.other).buyPack(created.editionId,PRICE,{value:PRICE}),'EnforcedPause');
    await expectCustomError(env.market.connect(env.other).buy(1,PRICE,{value:PRICE}),'MarketPaused');
    await (await env.market.connect(env.buyer).cancel(1)).wait();
    assert.equal(await env.packs.ownerOf(first),env.buyer.address);

    await (await env.manager.connect(env.governance).unpauseProtocol(digest('recovered'))).wait();
    assert.equal(await env.market.marketPaused(),false);
    await (await env.manager.connect(env.other).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
  });

  it('records overdue reveal incidents and still permits verified recovery reveals',async function(){
    const env=await deploy();
    const specs=[{indexes:[0],amounts:[1],salt:salt('incident-1')}];
    const created=await createEdition(env.manager,env.publisher,{key:'incident',specs,cardSupplies:[1],terminalRares:[false]});
    await (await env.manager.connect(env.reviewer).reviewEdition(created.editionId,2,digest('review'))).wait();
    await (await env.manager.connect(env.buyer).buyPack(created.editionId,PRICE,{value:PRICE})).wait();
    const token=packId(created.editionId,1);
    await (await env.manager.connect(env.buyer).requestOpen(token)).wait();
    await ethers.provider.send('evm_increaseTime',[HOUR+1]);
    await ethers.provider.send('evm_mine',[]);
    await (await env.manager.connect(env.buyer).flagRevealIncident(token,digest('overdue-proof'))).wait();
    assert.equal((await env.manager.revealIncident(token)).status,1n);
    await (await env.manager.connect(env.risk).resolveRevealIncident(token,digest('recovery-path'))).wait();
    await (await env.manager.connect(env.relayer).revealPack(token,{cardIndexes:[0],amounts:[1],salt:specs[0].salt,proof:created.tree.proof(0)})).wait();
    assert.equal(await env.cards.ownerOf(1),env.buyer.address);
    assert.equal((await env.manager.revealIncident(token)).status,2n);
  });
});
