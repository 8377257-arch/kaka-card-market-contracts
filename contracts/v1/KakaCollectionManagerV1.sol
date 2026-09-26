// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {KakaCardsV1} from "./KakaCardsV1.sol";
import {KakaPacksV1} from "./KakaPacksV1.sol";
import {KakaMarketplaceV1} from "./KakaMarketplaceV1.sol";

/// @title KAKA mainnet-v1 candidate controller
/// @notice Review-gated editions, unique card instances, signed burns, emergency pause and reveal incidents.
/// @dev Candidate only. It must not hold real funds before independent security review.
contract KakaCollectionManagerV1 is AccessControl,Pausable,ReentrancyGuard,EIP712 {
    enum IssuanceMode{Invalid,SellOutUnlock,TerminalRareBurn,OpenSale}
    enum ReviewStatus{None,Pending,Approved,Rejected,Suspended}
    enum BurnAssetKind{Invalid,Pack,Card}
    enum IncidentStatus{None,Flagged,Resolved}

    struct Edition{
        address publisher;IssuanceMode mode;ReviewStatus reviewStatus;uint256 packSize;uint256 packCount;
        uint256 soldPacks;uint256 openedPacks;uint256 destroyedPacks;uint256 voidedPacks;uint256 priceWei;
        uint256 proceedsWei;uint256 cardTypeCount;uint64 revealWindowSeconds;bytes32 editionKey;bytes32 contentRoot;
        bytes32 metadataDigest;bytes32 reviewEvidenceDigest;string metadataURI;string packURI;bool saleClosed;bool terminalConditionMet;
    }
    struct CardType{uint256 cardTypeId;uint256 maxSupply;uint256 mintedSupply;bytes32 metadataDigest;string tokenURI;bool terminalRare;}
    struct CreateEditionParams{
        bytes32 editionKey;IssuanceMode mode;uint256 packSize;uint256 packCount;uint256 priceWei;uint64 revealWindowSeconds;
        bytes32 contentRoot;bytes32 metadataDigest;string metadataURI;string packURI;bytes32[] cardMetadataDigests;
        string[] cardURIs;uint256[] cardSupplies;bool[] terminalRares;
    }
    struct RevealParams{uint256[] cardIndexes;uint256[] amounts;bytes32 salt;bytes32[] proof;}
    struct OpenRequest{address recipient;uint64 requestedAt;uint64 revealDeadline;bool requested;bool revealed;}
    struct RevealIncident{IncidentStatus status;bytes32 evidenceDigest;bytes32 resolutionDigest;uint64 flaggedAt;uint64 resolvedAt;}

    error InvalidAddress();error InvalidEdition();error InvalidEditionKey();error EditionKeyAlreadyUsed();error InvalidMode();
    error InvalidSupply();error InvalidPrice();error InvalidCommitmentRoot();error InvalidMetadata();error TooManyCardTypes();
    error ArrayLengthMismatch();error TerminalRareRequired();error ReviewPending();error InvalidReviewDecision();error InvalidReviewState();
    error SaleClosed();error SoldOut();error PriceChanged();error IncorrectPayment();error NotPackOwnerOrApproved();
    error OpeningNotAllowed();error OpenAlreadyRequested();error OpenNotRequested();error PackAlreadyRevealed();
    error InvalidPackContents();error CardIndexesNotStrictlyIncreasing();error InvalidContentProof();error OnlyPublisher();
    error NothingToWithdraw();error TransferFailed();error InvalidBurnIntent();error BurnIntentExpired();error InvalidBurnSigner();
    error BurnBatchTooLarge();error LockedPackCannotBurn();error RevealDeadlineNotReached();error InvalidIncidentState();
    error InvalidReasonDigest();error PublisherEditionLimit();error PublisherLimitReached();error InvalidIssuanceLimits();error IssuanceLimitDecrease();

    event EditionSubmitted(uint256 indexed editionId,address indexed publisher,bytes32 indexed editionKey,IssuanceMode mode,uint256 packCount,uint256 packSize,uint256 priceWei,bytes32 contentRoot,bytes32 metadataDigest);
    event CardTypeRegistered(uint256 indexed editionId,uint256 indexed cardIndex,uint256 indexed cardTypeId,uint256 maxSupply,bool terminalRare,bytes32 metadataDigest);
    event EditionReviewDecided(uint256 indexed editionId,ReviewStatus status,address indexed reviewer,bytes32 evidenceDigest);
    event EditionSuspended(uint256 indexed editionId,address indexed riskAdmin,bytes32 reasonDigest);
    event EditionResumed(uint256 indexed editionId,address indexed admin,bytes32 reasonDigest);
    event ProtocolPaused(address indexed riskAdmin,bytes32 indexed reasonDigest);
    event ProtocolUnpaused(address indexed admin,bytes32 indexed reasonDigest);
    event PackPurchased(uint256 indexed editionId,uint256 indexed packId,uint256 indexed packIndex,address buyer,uint256 priceWei);
    event PlatformFeePaid(uint256 indexed editionId,address indexed payer,address indexed recipient,uint256 amountWei);
    event PackOpenRequested(uint256 indexed editionId,uint256 indexed packId,address indexed recipient,uint64 revealDeadline);
    event PackRevealed(uint256 indexed editionId,uint256 indexed packId,address indexed recipient,uint256[] cardInstanceIds,uint256[] cardTypeIds);
    event TerminalConditionReached(uint256 indexed editionId,uint256 voidedPacks);
    event BurnIntentExecuted(address indexed owner,BurnAssetKind indexed assetKind,uint256 indexed nonce,uint256[] tokenIds);
    event RevealIncidentFlagged(uint256 indexed packId,address indexed reporter,bytes32 evidenceDigest);
    event RevealIncidentResolved(uint256 indexed packId,address indexed resolver,bytes32 resolutionDigest);
    event ProceedsWithdrawn(uint256 indexed editionId,address indexed publisher,address indexed recipient,uint256 amount);
    event PublisherSlotClaimed(address indexed publisher,uint256 indexed editionId,uint256 indexed publisherNumber);
    event IssuanceLimitsIncreased(uint256 publisherLimit,uint256 editionLimitPerPublisher,uint256 cardTypeLimit);

    bytes32 public constant RISK_ADMIN_ROLE=keccak256("RISK_ADMIN_ROLE");
    bytes32 public constant REVIEWER_ROLE=keccak256("REVIEWER_ROLE");
    bytes32 public constant COMMITMENT_DOMAIN=keccak256("KAKA_PACK_COMMITMENT_V1");
    bytes32 public constant BURN_INTENT_TYPEHASH=keccak256("BurnIntent(address owner,uint8 assetKind,uint256[] tokenIds,uint256 nonce,uint256 deadline)");
    uint256 public constant PLATFORM_FEE_BPS=500;uint256 public constant BPS_DENOMINATOR=10_000;
    uint256 public constant INITIAL_PUBLISHER_LIMIT=1_000;uint256 public constant INITIAL_EDITION_LIMIT_PER_PUBLISHER=1;
    uint256 public constant INITIAL_CARD_TYPE_LIMIT=30;uint256 public constant MAX_PACKS=100_000;uint256 public constant MAX_PACK_SIZE=50;
    uint256 public constant MAX_URI_BYTES=512;uint256 public constant MAX_BURN_BATCH=100;
    uint64 public constant MIN_REVEAL_WINDOW=1 hours;uint64 public constant MAX_REVEAL_WINDOW=30 days;

    address payable public immutable feeRecipient;KakaCardsV1 public immutable cards;KakaPacksV1 public immutable packs;KakaMarketplaceV1 public immutable marketplace;
    uint256 public nextEditionId=1;
    mapping(uint256=>Edition) private _editions;
    mapping(uint256=>mapping(uint256=>CardType)) private _cardTypes;
    mapping(address=>mapping(bytes32=>uint256)) public editionByPublisherKey;
    mapping(address=>uint256) public publisherEdition;mapping(address=>uint256) public publisherEditionCount;
    mapping(uint256=>OpenRequest) public openRequest;
    mapping(uint256=>RevealIncident) public revealIncident;
    mapping(address=>uint256) public burnNonce;
    uint256 public publisherCount;uint256 public publisherLimit=INITIAL_PUBLISHER_LIMIT;
    uint256 public editionLimitPerPublisher=INITIAL_EDITION_LIMIT_PER_PUBLISHER;uint256 public cardTypeLimit=INITIAL_CARD_TYPE_LIMIT;

    constructor(address governance,address riskAdmin,address reviewer) EIP712("KAKA CARD MARKET","1") {
        if(governance==address(0)||riskAdmin==address(0)||reviewer==address(0))revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE,governance);_grantRole(RISK_ADMIN_ROLE,riskAdmin);_grantRole(REVIEWER_ROLE,reviewer);
        feeRecipient=payable(governance);cards=new KakaCardsV1(address(this));packs=new KakaPacksV1(address(this));
        marketplace=new KakaMarketplaceV1(address(this),address(packs),address(cards),payable(governance));
    }

    function createEdition(CreateEditionParams calldata params) external whenNotPaused returns(uint256 editionId){
        uint256 cardCount=params.cardSupplies.length;
        if(publisherEditionCount[msg.sender]>=editionLimitPerPublisher)revert PublisherEditionLimit();
        if(publisherEditionCount[msg.sender]==0&&publisherCount>=publisherLimit)revert PublisherLimitReached();
        if(params.editionKey==bytes32(0))revert InvalidEditionKey();
        if(editionByPublisherKey[msg.sender][params.editionKey]!=0)revert EditionKeyAlreadyUsed();
        if(params.mode==IssuanceMode.Invalid)revert InvalidMode();
        if(params.packSize==0||params.packSize>MAX_PACK_SIZE||params.packCount==0||params.packCount>MAX_PACKS)revert InvalidSupply();
        if(params.priceWei==0)revert InvalidPrice();if(params.contentRoot==bytes32(0))revert InvalidCommitmentRoot();
        if(params.revealWindowSeconds<MIN_REVEAL_WINDOW||params.revealWindowSeconds>MAX_REVEAL_WINDOW)revert InvalidSupply();
        if(params.metadataDigest==bytes32(0)||!_validURI(params.metadataURI)||!_validURI(params.packURI))revert InvalidMetadata();
        if(cardCount==0||cardCount>cardTypeLimit)revert TooManyCardTypes();
        if(params.cardMetadataDigests.length!=cardCount||params.cardURIs.length!=cardCount||params.terminalRares.length!=cardCount)revert ArrayLengthMismatch();
        uint256 totalCards;uint256 terminalCount;
        for(uint256 i;i<cardCount;++i){
            if(params.cardSupplies[i]==0||params.cardMetadataDigests[i]==bytes32(0)||!_validURI(params.cardURIs[i]))revert InvalidMetadata();
            totalCards+=params.cardSupplies[i];if(params.terminalRares[i])++terminalCount;
        }
        if(totalCards!=params.packCount*params.packSize)revert InvalidSupply();
        if(params.mode==IssuanceMode.TerminalRareBurn&&terminalCount==0)revert TerminalRareRequired();
        editionId=nextEditionId++;editionByPublisherKey[msg.sender][params.editionKey]=editionId;
        if(publisherEditionCount[msg.sender]==0){publisherEdition[msg.sender]=editionId;++publisherCount;emit PublisherSlotClaimed(msg.sender,editionId,publisherCount);}
        ++publisherEditionCount[msg.sender];
        Edition storage edition=_editions[editionId];edition.publisher=msg.sender;edition.mode=params.mode;edition.reviewStatus=ReviewStatus.Pending;
        edition.packSize=params.packSize;edition.packCount=params.packCount;edition.priceWei=params.priceWei;edition.cardTypeCount=cardCount;
        edition.revealWindowSeconds=params.revealWindowSeconds;edition.editionKey=params.editionKey;edition.contentRoot=params.contentRoot;
        edition.metadataDigest=params.metadataDigest;edition.metadataURI=params.metadataURI;edition.packURI=params.packURI;
        for(uint256 i;i<cardCount;++i){
            uint256 typeId=_cardTypeId(editionId,i);_cardTypes[editionId][i]=CardType(typeId,params.cardSupplies[i],0,params.cardMetadataDigests[i],params.cardURIs[i],params.terminalRares[i]);
            emit CardTypeRegistered(editionId,i,typeId,params.cardSupplies[i],params.terminalRares[i],params.cardMetadataDigests[i]);
        }
        emit EditionSubmitted(editionId,msg.sender,params.editionKey,params.mode,params.packCount,params.packSize,params.priceWei,params.contentRoot,params.metadataDigest);
    }

    /// @notice Expands the current public capacity tier. Existing limits cannot be reduced.
    function increaseIssuanceLimits(uint256 publisherLimit_,uint256 editionLimitPerPublisher_,uint256 cardTypeLimit_) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(publisherLimit_==0||editionLimitPerPublisher_==0||cardTypeLimit_==0)revert InvalidIssuanceLimits();
        if(publisherLimit_<publisherLimit||editionLimitPerPublisher_<editionLimitPerPublisher||cardTypeLimit_<cardTypeLimit)revert IssuanceLimitDecrease();
        publisherLimit=publisherLimit_;editionLimitPerPublisher=editionLimitPerPublisher_;cardTypeLimit=cardTypeLimit_;
        emit IssuanceLimitsIncreased(publisherLimit_,editionLimitPerPublisher_,cardTypeLimit_);
    }

    function reviewEdition(uint256 editionId,ReviewStatus decision,bytes32 evidenceDigest) external onlyRole(REVIEWER_ROLE) whenNotPaused {
        Edition storage edition=_requireEdition(editionId);if(edition.reviewStatus!=ReviewStatus.Pending)revert InvalidReviewState();
        if(decision!=ReviewStatus.Approved&&decision!=ReviewStatus.Rejected)revert InvalidReviewDecision();
        if(evidenceDigest==bytes32(0))revert InvalidMetadata();edition.reviewStatus=decision;edition.reviewEvidenceDigest=evidenceDigest;
        if(decision==ReviewStatus.Rejected)edition.saleClosed=true;emit EditionReviewDecided(editionId,decision,msg.sender,evidenceDigest);
    }

    function suspendEdition(uint256 editionId,bytes32 reasonDigest) external onlyRole(RISK_ADMIN_ROLE){
        if(reasonDigest==bytes32(0))revert InvalidReasonDigest();
        Edition storage edition=_requireEdition(editionId);if(edition.reviewStatus!=ReviewStatus.Approved)revert InvalidReviewState();
        edition.reviewStatus=ReviewStatus.Suspended;emit EditionSuspended(editionId,msg.sender,reasonDigest);
    }
    function resumeEdition(uint256 editionId,bytes32 reasonDigest) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(reasonDigest==bytes32(0))revert InvalidReasonDigest();
        Edition storage edition=_requireEdition(editionId);if(edition.reviewStatus!=ReviewStatus.Suspended)revert InvalidReviewState();
        edition.reviewStatus=ReviewStatus.Approved;emit EditionResumed(editionId,msg.sender,reasonDigest);
    }
    function pauseProtocol(bytes32 reasonDigest) external onlyRole(RISK_ADMIN_ROLE){if(reasonDigest==bytes32(0))revert InvalidReasonDigest();_pause();marketplace.setMarketPaused(true,reasonDigest);emit ProtocolPaused(msg.sender,reasonDigest);}
    function unpauseProtocol(bytes32 reasonDigest) external onlyRole(DEFAULT_ADMIN_ROLE){if(reasonDigest==bytes32(0))revert InvalidReasonDigest();_unpause();marketplace.setMarketPaused(false,reasonDigest);emit ProtocolUnpaused(msg.sender,reasonDigest);}

    function buyPack(uint256 editionId,uint256 expectedPrice) external payable nonReentrant whenNotPaused returns(uint256 packId){
        Edition storage edition=_requireEdition(editionId);if(edition.reviewStatus!=ReviewStatus.Approved)revert ReviewPending();
        if(edition.saleClosed)revert SaleClosed();if(edition.soldPacks==edition.packCount)revert SoldOut();
        if(expectedPrice!=edition.priceWei)revert PriceChanged();if(msg.value!=edition.priceWei)revert IncorrectPayment();
        uint256 feeWei=msg.value*PLATFORM_FEE_BPS/BPS_DENOMINATOR;uint256 publisherAmount=msg.value-feeWei;
        uint256 packIndex=++edition.soldPacks;edition.proceedsWei+=publisherAmount;packId=_packTokenId(editionId,packIndex);
        packs.mint(msg.sender,packId,editionId,packIndex,edition.packURI);if(edition.soldPacks==edition.packCount)edition.saleClosed=true;
        if(feeWei!=0){(bool feePaid,)=feeRecipient.call{value:feeWei}("");if(!feePaid)revert TransferFailed();}
        emit PlatformFeePaid(editionId,msg.sender,feeRecipient,feeWei);
        emit PackPurchased(editionId,packId,packIndex,msg.sender,msg.value);
    }

    function requestOpen(uint256 packId) external whenNotPaused {
        uint256 editionId=packs.editionOf(packId);Edition storage edition=_requireEdition(editionId);address owner=packs.ownerOf(packId);
        if(msg.sender!=owner&&packs.getApproved(packId)!=msg.sender&&!packs.isApprovedForAll(owner,msg.sender))revert NotPackOwnerOrApproved();
        if(edition.mode==IssuanceMode.SellOutUnlock&&edition.soldPacks!=edition.packCount)revert OpeningNotAllowed();
        OpenRequest storage request=openRequest[packId];if(request.requested)revert OpenAlreadyRequested();
        uint64 requestedAt=uint64(block.timestamp);request.recipient=owner;request.requestedAt=requestedAt;request.revealDeadline=requestedAt+edition.revealWindowSeconds;request.requested=true;
        packs.setLocked(packId,true);emit PackOpenRequested(editionId,packId,owner,request.revealDeadline);
    }

    function revealPack(uint256 packId,RevealParams calldata params) external nonReentrant whenNotPaused {
        OpenRequest storage request=openRequest[packId];if(!request.requested)revert OpenNotRequested();if(request.revealed)revert PackAlreadyRevealed();
        uint256 editionId=packs.editionOf(packId);Edition storage edition=_requireEdition(editionId);uint256 packIndex=packs.packIndexOf(packId);
        _validatePackContents(editionId,params.cardIndexes,params.amounts);_verifyCommitment(editionId,packIndex,edition.contentRoot,params.cardIndexes,params.amounts,params.salt,params.proof);
        request.revealed=true;++edition.openedPacks;
        (uint256[] memory instanceIds,uint256[] memory typeIds)=_mintRevealedCards(editionId,request.recipient,edition.packSize,params.cardIndexes,params.amounts);
        packs.burn(packId);emit PackRevealed(editionId,packId,request.recipient,instanceIds,typeIds);_checkTerminalCondition(editionId,edition);
    }

    function executeBurn(address owner,BurnAssetKind assetKind,uint256[] calldata tokenIds,uint256 deadline,bytes calldata signature)
        external nonReentrant whenNotPaused
    {
        if(owner==address(0)||assetKind==BurnAssetKind.Invalid||tokenIds.length==0||tokenIds.length>MAX_BURN_BATCH)revert InvalidBurnIntent();
        if(block.timestamp>deadline)revert BurnIntentExpired();uint256 nonce=burnNonce[owner];bytes32 tokenIdsHash=keccak256(abi.encodePacked(tokenIds));
        bytes32 digest=_hashTypedDataV4(keccak256(abi.encode(BURN_INTENT_TYPEHASH,owner,uint8(assetKind),tokenIdsHash,nonce,deadline)));
        if(ECDSA.recover(digest,signature)!=owner)revert InvalidBurnSigner();burnNonce[owner]=nonce+1;
        if(assetKind==BurnAssetKind.Pack){
            for(uint256 i;i<tokenIds.length;++i){if(openRequest[tokenIds[i]].requested||packs.isLocked(tokenIds[i]))revert LockedPackCannotBurn();++_editions[packs.editionOf(tokenIds[i])].destroyedPacks;}
            packs.burnBatchFrom(owner,tokenIds);
        }else cards.burnBatchFrom(owner,tokenIds);
        emit BurnIntentExecuted(owner,assetKind,nonce,tokenIds);
    }

    function flagRevealIncident(uint256 packId,bytes32 evidenceDigest) external {
        if(evidenceDigest==bytes32(0))revert InvalidReasonDigest();
        OpenRequest storage request=openRequest[packId];if(!request.requested||request.revealed||block.timestamp<=request.revealDeadline)revert RevealDeadlineNotReached();
        if(msg.sender!=request.recipient&&!hasRole(RISK_ADMIN_ROLE,msg.sender))revert NotPackOwnerOrApproved();
        RevealIncident storage incident=revealIncident[packId];if(incident.status!=IncidentStatus.None)revert InvalidIncidentState();
        incident.status=IncidentStatus.Flagged;incident.evidenceDigest=evidenceDigest;incident.flaggedAt=uint64(block.timestamp);emit RevealIncidentFlagged(packId,msg.sender,evidenceDigest);
    }
    function resolveRevealIncident(uint256 packId,bytes32 resolutionDigest) external onlyRole(RISK_ADMIN_ROLE){
        if(resolutionDigest==bytes32(0))revert InvalidReasonDigest();
        RevealIncident storage incident=revealIncident[packId];if(incident.status!=IncidentStatus.Flagged)revert InvalidIncidentState();
        incident.status=IncidentStatus.Resolved;incident.resolutionDigest=resolutionDigest;incident.resolvedAt=uint64(block.timestamp);emit RevealIncidentResolved(packId,msg.sender,resolutionDigest);
    }

    function withdrawProceeds(uint256 editionId,address payable recipient) external nonReentrant {
        Edition storage edition=_requireEdition(editionId);if(msg.sender!=edition.publisher)revert OnlyPublisher();if(recipient==address(0))revert TransferFailed();
        uint256 amount=edition.proceedsWei;if(amount==0)revert NothingToWithdraw();edition.proceedsWei=0;(bool success,)=recipient.call{value:amount}("");if(!success)revert TransferFailed();
        emit ProceedsWithdrawn(editionId,msg.sender,recipient,amount);
    }

    function commitmentLeaf(uint256 editionId,uint256 packIndex,uint256[] calldata cardIndexes,uint256[] calldata amounts,bytes32 salt) public view returns(bytes32){
        bytes32 contentDigest=keccak256(abi.encode(cardIndexes,amounts,salt));bytes32 inner=keccak256(abi.encode(COMMITMENT_DOMAIN,block.chainid,address(this),editionId,packIndex,contentDigest));return keccak256(bytes.concat(inner));
    }
    function getEdition(uint256 editionId) external view returns(Edition memory){return _requireEdition(editionId);}
    function getCardType(uint256 editionId,uint256 cardIndex) external view returns(CardType memory){_requireEdition(editionId);if(cardIndex>=_editions[editionId].cardTypeCount)revert InvalidPackContents();return _cardTypes[editionId][cardIndex];}
    function canOpen(uint256 editionId) external view returns(bool){Edition storage edition=_requireEdition(editionId);return edition.mode!=IssuanceMode.SellOutUnlock||edition.soldPacks==edition.packCount;}
    function burnIntentDigest(address owner,BurnAssetKind assetKind,uint256[] calldata tokenIds,uint256 nonce,uint256 deadline) external view returns(bytes32){return _hashTypedDataV4(keccak256(abi.encode(BURN_INTENT_TYPEHASH,owner,uint8(assetKind),keccak256(abi.encodePacked(tokenIds)),nonce,deadline)));}

    function _validatePackContents(uint256 editionId,uint256[] calldata cardIndexes,uint256[] calldata amounts) private view {
        Edition storage edition=_editions[editionId];if(cardIndexes.length==0||cardIndexes.length!=amounts.length||cardIndexes.length>edition.cardTypeCount)revert InvalidPackContents();
        uint256 totalAmount;for(uint256 i;i<cardIndexes.length;++i){if(i>0&&cardIndexes[i-1]>=cardIndexes[i])revert CardIndexesNotStrictlyIncreasing();uint256 index=cardIndexes[i];uint256 amount=amounts[i];if(index>=edition.cardTypeCount||amount==0)revert InvalidPackContents();CardType storage cardType=_cardTypes[editionId][index];if(cardType.mintedSupply+amount>cardType.maxSupply)revert InvalidPackContents();totalAmount+=amount;}
        if(totalAmount!=edition.packSize)revert InvalidPackContents();
    }
    function _mintRevealedCards(uint256 editionId,address recipient,uint256 packSize,uint256[] calldata cardIndexes,uint256[] calldata amounts) private returns(uint256[] memory instanceIds,uint256[] memory typeIds){
        instanceIds=new uint256[](packSize);typeIds=new uint256[](packSize);uint256 cursor;
        for(uint256 i;i<cardIndexes.length;++i){
            (uint256[] memory minted,uint256 cardTypeId)=_mintOneCardType(editionId,recipient,cardIndexes[i],amounts[i]);
            for(uint256 j;j<minted.length;++j){instanceIds[cursor]=minted[j];typeIds[cursor]=cardTypeId;++cursor;}
        }
    }
    function _mintOneCardType(uint256 editionId,address recipient,uint256 cardIndex,uint256 amount) private returns(uint256[] memory minted,uint256 cardTypeId){
        CardType storage cardType=_cardTypes[editionId][cardIndex];cardType.mintedSupply+=amount;cardTypeId=cardType.cardTypeId;
        minted=cards.mintBatch(recipient,editionId,cardIndex,cardTypeId,amount,cardType.tokenURI);
    }
    function _verifyCommitment(uint256 editionId,uint256 packIndex,bytes32 root,uint256[] calldata indexes,uint256[] calldata amounts,bytes32 salt,bytes32[] calldata proof) private view {if(!MerkleProof.verifyCalldata(proof,root,commitmentLeaf(editionId,packIndex,indexes,amounts,salt)))revert InvalidContentProof();}
    function _checkTerminalCondition(uint256 editionId,Edition storage edition) private {if(edition.mode!=IssuanceMode.TerminalRareBurn||edition.terminalConditionMet)return;for(uint256 i;i<edition.cardTypeCount;++i){CardType storage cardType=_cardTypes[editionId][i];if(cardType.terminalRare&&cardType.mintedSupply!=cardType.maxSupply)return;}edition.terminalConditionMet=true;edition.saleClosed=true;edition.voidedPacks=edition.packCount-edition.soldPacks;emit TerminalConditionReached(editionId,edition.voidedPacks);}
    function _requireEdition(uint256 editionId) private view returns(Edition storage edition){edition=_editions[editionId];if(edition.publisher==address(0))revert InvalidEdition();}
    function _validURI(string calldata value) private pure returns(bool){uint256 length=bytes(value).length;return length>0&&length<=MAX_URI_BYTES;}
    function _cardTypeId(uint256 editionId,uint256 cardIndex) private pure returns(uint256){return(editionId<<32)|(cardIndex+1);}
    function _packTokenId(uint256 editionId,uint256 packIndex) private pure returns(uint256){return(editionId<<64)|packIndex;}
}
