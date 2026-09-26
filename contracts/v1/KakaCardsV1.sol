// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

/// @notice Unique card instances for the mainnet-v1 candidate.
/// @dev The controller assigns every instance id. Burned ids are never reused.
contract KakaCardsV1 is ERC721URIStorage {
    struct CardInstance {
        uint256 editionId;
        uint256 cardIndex;
        uint256 cardTypeId;
        uint256 serial;
    }

    error OnlyController();
    error InvalidController();
    error InvalidMint();
    error NotTokenOwner(uint256 tokenId);

    address public immutable controller;
    uint256 public nextInstanceId = 1;
    mapping(uint256 tokenId => CardInstance instance) public cardInstance;
    mapping(uint256 cardTypeId => uint256 serial) public nextSerial;

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor(address controller_) ERC721("KAKA Unique Card", "KCARD") {
        if (controller_ == address(0)) revert InvalidController();
        controller = controller_;
    }

    function mintBatch(
        address recipient,
        uint256 editionId,
        uint256 cardIndex,
        uint256 cardTypeId,
        uint256 amount,
        string calldata tokenURI
    ) external onlyController returns (uint256[] memory tokenIds) {
        if (recipient == address(0) || editionId == 0 || cardTypeId == 0 || amount == 0 || bytes(tokenURI).length == 0) {
            revert InvalidMint();
        }
        tokenIds = new uint256[](amount);
        for (uint256 i; i < amount; ++i) {
            uint256 tokenId = nextInstanceId++;
            uint256 serial = ++nextSerial[cardTypeId];
            cardInstance[tokenId] = CardInstance(editionId, cardIndex, cardTypeId, serial);
            tokenIds[i] = tokenId;
            _safeMint(recipient, tokenId);
            _setTokenURI(tokenId, tokenURI);
        }
    }

    function burnBatchFrom(address owner, uint256[] calldata tokenIds) external onlyController {
        if (owner == address(0) || tokenIds.length == 0) revert InvalidMint();
        for (uint256 i; i < tokenIds.length; ++i) {
            if (_ownerOf(tokenIds[i]) != owner) revert NotTokenOwner(tokenIds[i]);
            _burn(tokenIds[i]);
        }
    }

}
