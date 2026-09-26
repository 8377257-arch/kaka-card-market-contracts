// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

/// @notice Individually numbered sealed packs for the mainnet-v1 candidate.
contract KakaPacksV1 is ERC721URIStorage {
    error OnlyController();
    error InvalidController();
    error PackLocked(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);

    address public immutable controller;
    mapping(uint256 tokenId => uint256) public editionOf;
    mapping(uint256 tokenId => uint256) public packIndexOf;
    mapping(uint256 tokenId => bool) public isLocked;

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor(address controller_) ERC721("KAKA Sealed Pack V1", "KPACK1") {
        if (controller_ == address(0)) revert InvalidController();
        controller = controller_;
    }

    function mint(address recipient,uint256 tokenId,uint256 editionId,uint256 packIndex,string calldata tokenURI)
        external onlyController
    {
        editionOf[tokenId]=editionId;
        packIndexOf[tokenId]=packIndex;
        _safeMint(recipient,tokenId);
        _setTokenURI(tokenId,tokenURI);
    }

    function setLocked(uint256 tokenId,bool locked) external onlyController {
        _requireOwned(tokenId);
        isLocked[tokenId]=locked;
    }

    function burn(uint256 tokenId) external onlyController {_burn(tokenId);}

    function burnBatchFrom(address owner,uint256[] calldata tokenIds) external onlyController {
        for(uint256 i;i<tokenIds.length;++i){
            if(_ownerOf(tokenIds[i])!=owner)revert NotTokenOwner(tokenIds[i]);
            if(isLocked[tokenIds[i]])revert PackLocked(tokenIds[i]);
            _burn(tokenIds[i]);
        }
    }

    function _update(address to,uint256 tokenId,address auth) internal override returns(address){
        address from=_ownerOf(tokenId);
        if(from!=address(0)&&to!=address(0)&&isLocked[tokenId])revert PackLocked(tokenId);
        return super._update(to,tokenId,auth);
    }

}
