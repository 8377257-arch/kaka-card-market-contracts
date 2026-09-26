const assert=require('node:assert/strict');
const {ethers}=require('hardhat');

const PRICE=ethers.parseEther('0.0001');
const HOUR=3600;

function seededRandom(seed){
  let state=seed>>>0;
  return max=>{state=(Math.imul(state,1664525)+1013904223)>>>0;return state%max;};
}
function hash(label){return ethers.keccak256(ethers.toUtf8Bytes(label));}
function pairHash(a,b){const [left,right]=BigInt(a)<BigInt(b)?[a,b]:[b,a];return ethers.keccak256(ethers.concat([left,right]));}
function packId(editionId,index){return (BigInt(editionId)<<64n)|BigInt(index);}
function merkleTree(leaves){
  const layers=[leaves];
  while(layers.at(-1).length>1){
    const current=layers.at(-1),next=[];
    for(let i=0;i<current.length;i+=2)next.push(pairHash(current[i],current[i+1]??current[i]));
    layers.push(next);
  }
  return {root:layers.at(-1)[0],proof(index){const proof=[];for(let level=0;level<layers.length-1;level++){const sibling=index^1,current=layers[level];proof.push(current[sibling]??current[index]);index=Math.floor(index/2);}return proof;}};
}
async function expectCustomError(action,name){
  try{const tx=await action;if(tx?.wait)await tx.wait();assert.fail(`Expected ${name}`);}
  catch(error){if(error.code==='ERR_ASSERTION')throw error;assert.match(String(error.shortMessage||error.message),new RegExp(name),String(error));}
}
async function deploy(){
  const [governance,risk,reviewer,publisher,relayer,...allUsers]=await ethers.getSigners(),users=allUsers.slice(0,4),publishers=[publisher,...allUsers.slice(4,15)];
  const Factory=await ethers.getContractFactory('KakaCollectionManagerV1');
  const manager=await Factory.deploy(governance.address,risk.address,reviewer.address);await manager.waitForDeployment();
  return {
    manager,governance,risk,reviewer,publisher,relayer,users,publishers,
    cards:await ethers.getContractAt('KakaCardsV1',await manager.cards()),
    packs:await ethers.getContractAt('KakaPacksV1',await manager.packs()),
    market:await ethers.getContractAt('KakaMarketplaceV1',await manager.marketplace())
  };
}
async function signBurn(manager,signer,assetKind,tokenIds,deadline){
  const network=await ethers.provider.getNetwork(),nonce=await manager.burnNonce(signer.address);
  return signer.signTypedData(
    {name:'KAKA CARD MARKET',version:'1',chainId:network.chainId,verifyingContract:await manager.getAddress()},
    {BurnIntent:[{name:'owner',type:'address'},{name:'assetKind',type:'uint8'},{name:'tokenIds',type:'uint256[]'},{name:'nonce',type:'uint256'},{name:'deadline',type:'uint256'}]},
    {owner:signer.address,assetKind,tokenIds,nonce,deadline}
  );
}
function makeScenario(random,scenario){
  const packCount=3+random(4),packSize=1+random(5),totalCards=packCount*packSize,maxCardCount=Math.min(5,totalCards),cardCount=2+random(maxCardCount-1),specs=[],supplies=Array(cardCount).fill(0),deck=[];
  for(let cardIndex=0;cardIndex<cardCount;cardIndex++)deck.push(cardIndex);
  while(deck.length<totalCards)deck.push(random(cardCount));
  for(let i=deck.length-1;i>0;i--){const j=random(i+1);[deck[i],deck[j]]=[deck[j],deck[i]];}
  for(let pack=0;pack<packCount;pack++){
    const counts=Array(cardCount).fill(0);
    for(let slot=0;slot<packSize;slot++)counts[deck[pack*packSize+slot]]++;
    const indexes=[],amounts=[];
    counts.forEach((amount,index)=>{if(amount){indexes.push(index);amounts.push(amount);supplies[index]+=amount;}});
    specs.push({indexes,amounts,salt:hash(`invariant:${scenario}:${pack}`)});
  }
  return {packCount,packSize,cardCount,specs,supplies};
}

describe('KAKA mainnet-v1 stateful invariants',function(){
  it('preserves fixed supply, unique ids, ownership and burn accounting across reproducible randomized sequences',async function(){
    const env=await deploy(),random=seededRandom(0x4b414b41),signerByAddress=new Map(env.users.map(user=>[user.address.toLowerCase(),user]));
    let expectedNextInstanceId=1n,totalMinted=0n,totalBurnedCards=0n;

    for(let scenarioIndex=0;scenarioIndex<12;scenarioIndex++){
      const scenario=makeScenario(random,scenarioIndex),editionId=await env.manager.nextEditionId(),leaves=[];
      for(let i=0;i<scenario.packCount;i++)leaves.push(await env.manager.commitmentLeaf(editionId,i+1,scenario.specs[i].indexes,scenario.specs[i].amounts,scenario.specs[i].salt));
      const tree=merkleTree(leaves),key=`stateful-${scenarioIndex}`;
      await (await env.manager.connect(env.publishers[scenarioIndex]).createEdition({
        editionKey:hash(key),mode:3,packSize:scenario.packSize,packCount:scenario.packCount,priceWei:PRICE,revealWindowSeconds:HOUR,
        contentRoot:tree.root,metadataDigest:hash(`${key}:metadata`),metadataURI:`ipfs://${key}/collection.json`,packURI:`ipfs://${key}/pack.json`,
        cardMetadataDigests:scenario.supplies.map((_,i)=>hash(`${key}:card:${i}`)),cardURIs:scenario.supplies.map((_,i)=>`ipfs://${key}/cards/${i}.json`),
        cardSupplies:scenario.supplies,terminalRares:scenario.supplies.map(()=>false)
      })).wait();
      await (await env.manager.connect(env.reviewer).reviewEdition(editionId,2,hash(`${key}:approved`))).wait();

      const packStates=[],mintedByOwner=new Map(),revealedCounts=Array(scenario.cardCount).fill(0);
      let opened=0,destroyed=0;
      for(let index=1;index<=scenario.packCount;index++){
        const initialOwner=env.users[(scenarioIndex+index)%env.users.length];
        await (await env.manager.connect(initialOwner).buyPack(editionId,PRICE,{value:PRICE})).wait();
        let owner=initialOwner;
        if(random(4)===0){
          const recipient=env.users[(scenarioIndex+index+1)%env.users.length];
          await (await env.packs.connect(owner).transferFrom(owner.address,recipient.address,packId(editionId,index))).wait();owner=recipient;
        }
        packStates.push({index,owner,action:random(3)});
      }

      const burnPacksByOwner=new Map();
      for(const state of packStates){
        const token=packId(editionId,state.index),spec=scenario.specs[state.index-1];
        if(state.action===0){
          const firstId=await env.cards.nextInstanceId();
          await (await env.manager.connect(state.owner).requestOpen(token)).wait();
          await (await env.manager.connect(env.relayer).revealPack(token,{cardIndexes:spec.indexes,amounts:spec.amounts,salt:spec.salt,proof:tree.proof(state.index-1)})).wait();
          const ids=Array.from({length:scenario.packSize},(_,offset)=>firstId+BigInt(offset));
          const ownerKey=state.owner.address.toLowerCase();mintedByOwner.set(ownerKey,[...(mintedByOwner.get(ownerKey)||[]),...ids]);
          spec.indexes.forEach((cardIndex,i)=>revealedCounts[cardIndex]+=spec.amounts[i]);opened++;totalMinted+=BigInt(scenario.packSize);expectedNextInstanceId+=BigInt(scenario.packSize);
        }else if(state.action===1){
          const ownerKey=state.owner.address.toLowerCase();burnPacksByOwner.set(ownerKey,[...(burnPacksByOwner.get(ownerKey)||[]),token]);
        }
      }
      for(const [ownerKey,tokenIds] of burnPacksByOwner){
        const owner=signerByAddress.get(ownerKey),deadline=BigInt((await ethers.provider.getBlock('latest')).timestamp+HOUR),signature=await signBurn(env.manager,owner,1,tokenIds,deadline);
        await (await env.manager.connect(env.relayer).executeBurn(owner.address,1,tokenIds,deadline,signature)).wait();destroyed+=tokenIds.length;
      }

      for(const [ownerKey,tokenIds] of mintedByOwner){
        const selected=tokenIds.filter((_,index)=>index%2===scenarioIndex%2);if(!selected.length)continue;
        const owner=signerByAddress.get(ownerKey),deadline=BigInt((await ethers.provider.getBlock('latest')).timestamp+HOUR),signature=await signBurn(env.manager,owner,2,selected,deadline);
        await (await env.manager.connect(env.relayer).executeBurn(owner.address,2,selected,deadline,signature)).wait();totalBurnedCards+=BigInt(selected.length);
      }

      const edition=await env.manager.getEdition(editionId);
      assert.equal(edition.soldPacks,BigInt(scenario.packCount));
      assert.equal(edition.openedPacks,BigInt(opened));
      assert.equal(edition.destroyedPacks,BigInt(destroyed));
      assert.ok(edition.openedPacks+edition.destroyedPacks<=edition.soldPacks);
      assert.equal(revealedCounts.reduce((sum,value)=>sum+value,0),opened*scenario.packSize);
      for(let cardIndex=0;cardIndex<scenario.cardCount;cardIndex++){
        const cardType=await env.manager.getCardType(editionId,cardIndex);
        assert.equal(cardType.maxSupply,BigInt(scenario.supplies[cardIndex]));
        assert.equal(cardType.mintedSupply,BigInt(revealedCounts[cardIndex]));
        assert.ok(cardType.mintedSupply<=cardType.maxSupply);
      }
      assert.equal(await env.cards.nextInstanceId(),expectedNextInstanceId);
      const liveBalance=(await Promise.all(env.users.map(user=>env.cards.balanceOf(user.address)))).reduce((sum,value)=>sum+value,0n);
      assert.equal(liveBalance,totalMinted-totalBurnedCards);
    }
  });

  it('enforces the governance, risk, reviewer and controller boundaries',async function(){
    const env=await deploy(),outsider=env.users[0],zero=ethers.ZeroHash;
    await expectCustomError(env.manager.connect(outsider).pauseProtocol(hash('unauthorized')),'AccessControlUnauthorizedAccount');
    await expectCustomError(env.manager.connect(env.reviewer).pauseProtocol(hash('wrong-role')),'AccessControlUnauthorizedAccount');
    await expectCustomError(env.manager.connect(env.risk).unpauseProtocol(hash('wrong-role')),'AccessControlUnauthorizedAccount');
    await expectCustomError(env.manager.connect(env.risk).pauseProtocol(zero),'InvalidReasonDigest');
    await expectCustomError(env.cards.connect(outsider).mintBatch(outsider.address,1,0,1,1,'ipfs://unauthorized'),'OnlyController');
    await expectCustomError(env.packs.connect(outsider).setLocked(1,true),'OnlyController');
    await expectCustomError(env.market.connect(outsider).setMarketPaused(true,hash('unauthorized')),'OnlyController');
  });
});
