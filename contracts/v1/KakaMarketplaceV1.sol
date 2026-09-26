// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KakaCardsV1} from "./KakaCardsV1.sol";
import {KakaPacksV1} from "./KakaPacksV1.sol";

/// @notice Fixed-price escrow market for unique v1 packs and card instances.
/// @dev Cancellation and proceeds withdrawal remain available while new market actions are paused.
contract KakaMarketplaceV1 is ERC721Holder,ReentrancyGuard {
    enum AssetKind{Invalid,Pack,Card}
    struct Listing{address seller;AssetKind assetKind;uint256 tokenId;uint256 unitPriceWei;uint64 expiresAt;bool active;}

    error OnlyController();error InvalidContracts();error MarketPaused();error InvalidListing();error InvalidPrice();
    error InvalidExpiry();error NotAssetOwner();error PackNotTradeable();error ListingInactive();error ListingExpired();
    error OnlySeller();error PriceChanged(uint256 expected,uint256 actual);error IncorrectPayment(uint256 expected,uint256 actual);
    error NothingToWithdraw();error TransferFailed();

    event MarketPauseChanged(bool paused,bytes32 indexed reasonDigest);
    event ListingCreated(uint256 indexed listingId,address indexed seller,AssetKind indexed assetKind,uint256 tokenId,uint256 unitPriceWei,uint64 expiresAt);
    event ListingPurchased(uint256 indexed listingId,address indexed buyer,address indexed seller,uint256 tokenId,uint256 totalPriceWei);
    event PlatformFeePaid(uint256 indexed listingId,address indexed payer,address indexed recipient,uint256 amountWei);
    event ListingCancelled(uint256 indexed listingId,address indexed seller,uint256 tokenId);
    event ProceedsWithdrawn(address indexed seller,address indexed recipient,uint256 amount);

    uint256 public constant PLATFORM_FEE_BPS=500;uint256 public constant BPS_DENOMINATOR=10_000;
    address public immutable controller;address payable public immutable feeRecipient;KakaPacksV1 public immutable packs;KakaCardsV1 public immutable cards;
    bool public marketPaused;uint256 public nextListingId=1;
    mapping(uint256=>Listing) private _listings;mapping(address=>uint256) public sellerProceeds;

    modifier onlyController(){if(msg.sender!=controller)revert OnlyController();_;}
    modifier whenMarketOpen(){if(marketPaused)revert MarketPaused();_;}

    constructor(address controller_,address packs_,address cards_,address payable feeRecipient_){
        if(controller_==address(0)||packs_==address(0)||cards_==address(0)||feeRecipient_==address(0))revert InvalidContracts();
        controller=controller_;feeRecipient=feeRecipient_;packs=KakaPacksV1(packs_);cards=KakaCardsV1(cards_);
    }

    function setMarketPaused(bool paused_,bytes32 reasonDigest) external onlyController {
        marketPaused=paused_;emit MarketPauseChanged(paused_,reasonDigest);
    }

    function listPack(uint256 tokenId,uint256 unitPriceWei,uint64 expiresAt) external nonReentrant whenMarketOpen returns(uint256){
        if(packs.ownerOf(tokenId)!=msg.sender)revert NotAssetOwner();
        if(packs.isLocked(tokenId))revert PackNotTradeable();
        uint256 listingId=_createListing(msg.sender,AssetKind.Pack,tokenId,unitPriceWei,expiresAt);
        packs.safeTransferFrom(msg.sender,address(this),tokenId);return listingId;
    }

    function listCard(uint256 tokenId,uint256 unitPriceWei,uint64 expiresAt) external nonReentrant whenMarketOpen returns(uint256){
        if(cards.ownerOf(tokenId)!=msg.sender)revert NotAssetOwner();
        uint256 listingId=_createListing(msg.sender,AssetKind.Card,tokenId,unitPriceWei,expiresAt);
        cards.safeTransferFrom(msg.sender,address(this),tokenId);return listingId;
    }

    function buy(uint256 listingId,uint256 expectedUnitPrice) external payable nonReentrant whenMarketOpen {
        Listing storage listing=_requireActive(listingId);
        if(listing.expiresAt!=0&&block.timestamp>=listing.expiresAt)revert ListingExpired();
        if(expectedUnitPrice!=listing.unitPriceWei)revert PriceChanged(expectedUnitPrice,listing.unitPriceWei);
        if(msg.value!=listing.unitPriceWei)revert IncorrectPayment(listing.unitPriceWei,msg.value);
        uint256 feeWei=msg.value*PLATFORM_FEE_BPS/BPS_DENOMINATOR;uint256 sellerAmount=msg.value-feeWei;
        listing.active=false;sellerProceeds[listing.seller]+=sellerAmount;
        if(listing.assetKind==AssetKind.Pack)packs.safeTransferFrom(address(this),msg.sender,listing.tokenId);
        else cards.safeTransferFrom(address(this),msg.sender,listing.tokenId);
        if(feeWei!=0){(bool feePaid,)=feeRecipient.call{value:feeWei}("");if(!feePaid)revert TransferFailed();}
        emit PlatformFeePaid(listingId,msg.sender,feeRecipient,feeWei);
        emit ListingPurchased(listingId,msg.sender,listing.seller,listing.tokenId,msg.value);
    }

    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing=_requireActive(listingId);if(msg.sender!=listing.seller)revert OnlySeller();listing.active=false;
        if(listing.assetKind==AssetKind.Pack)packs.safeTransferFrom(address(this),listing.seller,listing.tokenId);
        else cards.safeTransferFrom(address(this),listing.seller,listing.tokenId);
        emit ListingCancelled(listingId,listing.seller,listing.tokenId);
    }

    function withdrawProceeds(address payable recipient) external nonReentrant {
        if(recipient==address(0))revert TransferFailed();uint256 amount=sellerProceeds[msg.sender];if(amount==0)revert NothingToWithdraw();
        sellerProceeds[msg.sender]=0;(bool success,)=recipient.call{value:amount}("");if(!success)revert TransferFailed();
        emit ProceedsWithdrawn(msg.sender,recipient,amount);
    }

    function getListing(uint256 listingId) external view returns(Listing memory){Listing memory listing=_listings[listingId];if(listing.seller==address(0))revert InvalidListing();return listing;}

    function _createListing(address seller,AssetKind assetKind,uint256 tokenId,uint256 unitPriceWei,uint64 expiresAt) private returns(uint256 listingId){
        if(unitPriceWei==0)revert InvalidPrice();if(expiresAt!=0&&expiresAt<=block.timestamp)revert InvalidExpiry();listingId=nextListingId++;
        _listings[listingId]=Listing(seller,assetKind,tokenId,unitPriceWei,expiresAt,true);emit ListingCreated(listingId,seller,assetKind,tokenId,unitPriceWei,expiresAt);
    }
    function _requireActive(uint256 listingId) private view returns(Listing storage listing){listing=_listings[listingId];if(listing.seller==address(0))revert InvalidListing();if(!listing.active)revert ListingInactive();}
}
