// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ETHCali Ticket Validator
/// @notice Issues non-transferable attendance tickets whose canonical proof is a hash.
contract ETHCaliTicketValidator is ERC721, Ownable, ReentrancyGuard {
    error InvalidRecipient();
    error InvalidTicketHash();
    error TicketAlreadyIssued();
    error SoulboundTransfer();
    error TicketDoesNotExist();
    error TicketAlreadyConsumed();
    error InvalidPrice();
    error TicketNotListed();
    error IncorrectPayment();
    error SellerPaymentFailed();
    error Unauthorized();
    error WithdrawalFailed();

    uint256 private _nextTokenId = 1;
    mapping(bytes32 ticketHash => uint256 tokenId) private _tokenIdByHash;
    mapping(uint256 tokenId => bytes32 ticketHash) private _hashByTokenId;
    mapping(uint256 tokenId => string uri) private _tokenURIs;
    mapping(uint256 tokenId => bool consumed) public consumed;
    mapping(uint256 => uint256) public ticketPrices;
    bool private _marketTransferInProgress;

    event TicketIssued(address indexed recipient, uint256 indexed tokenId, bytes32 indexed ticketHash, string metadataURI);
    event TicketRevoked(uint256 indexed tokenId, bytes32 indexed ticketHash);
    event TicketConsumed(uint256 indexed tokenId, address indexed attendee);
    event TicketListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event TicketSold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);

    constructor() ERC721("ETHCali Ticket", "ETHCALI") Ownable(msg.sender) {}

    function mintTicket(address to) external onlyOwner returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidRecipient();

        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        emit TicketIssued(to, tokenId, bytes32(0), "");
    }

    function consumeTicket(uint256 tokenId) external onlyOwner {
        if (_ownerOf(tokenId) == address(0)) revert TicketDoesNotExist();
        if (consumed[tokenId]) revert TicketAlreadyConsumed();

        consumed[tokenId] = true;
        delete ticketPrices[tokenId];
        emit TicketConsumed(tokenId, ownerOf(tokenId));
    }

    function listTicket(uint256 tokenId, uint256 price) external {
        if (_ownerOf(tokenId) != msg.sender) revert Unauthorized();
        if (consumed[tokenId]) revert TicketAlreadyConsumed();
        if (price == 0) revert InvalidPrice();

        ticketPrices[tokenId] = price;
        emit TicketListed(tokenId, msg.sender, price);
    }

    function buyTicket(uint256 tokenId) external payable nonReentrant {
        address seller = _ownerOf(tokenId);
        uint256 price = ticketPrices[tokenId];

        if (seller == address(0)) revert TicketDoesNotExist();
        if (consumed[tokenId]) revert TicketAlreadyConsumed();
        if (price == 0) revert TicketNotListed();
        if (msg.value != price) revert IncorrectPayment();
        if (msg.sender == seller) revert Unauthorized();

        delete ticketPrices[tokenId];
        _marketTransferInProgress = true;
        _update(msg.sender, tokenId, address(0));
        _marketTransferInProgress = false;

        (bool paid, ) = seller.call{value: (price * 90) / 100}("");
        if (!paid) revert SellerPaymentFailed();

        emit TicketSold(tokenId, seller, msg.sender, price);
    }

    function withdraw() external nonReentrant onlyOwner {
        (bool withdrawn, ) = owner().call{value: address(this).balance}("");
        if (!withdrawn) revert WithdrawalFailed();
    }

    function issueTicket(address recipient, bytes32 ticketHash, string calldata metadataURI)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        if (recipient == address(0)) revert InvalidRecipient();
        if (ticketHash == bytes32(0)) revert InvalidTicketHash();
        if (_tokenIdByHash[ticketHash] != 0) revert TicketAlreadyIssued();

        tokenId = _nextTokenId++;
        _tokenIdByHash[ticketHash] = tokenId;
        _hashByTokenId[tokenId] = ticketHash;
        _tokenURIs[tokenId] = metadataURI;
        _safeMint(recipient, tokenId);

        emit TicketIssued(recipient, tokenId, ticketHash, metadataURI);
    }

    function revokeTicket(uint256 tokenId) external onlyOwner {
        if (_ownerOf(tokenId) == address(0)) revert TicketDoesNotExist();

        bytes32 ticketHash = _hashByTokenId[tokenId];
        delete _tokenIdByHash[ticketHash];
        delete _hashByTokenId[tokenId];
        delete _tokenURIs[tokenId];
        delete consumed[tokenId];
        delete ticketPrices[tokenId];
        _burn(tokenId);

        emit TicketRevoked(tokenId, ticketHash);
    }

    function tokenIdForHash(bytes32 ticketHash) external view returns (uint256) {
        return _tokenIdByHash[ticketHash];
    }

    function ticketHash(uint256 tokenId) external view returns (bytes32) {
        if (_ownerOf(tokenId) == address(0)) revert TicketDoesNotExist();
        return _hashByTokenId[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert TicketDoesNotExist();
        return _tokenURIs[tokenId];
    }

    function approve(address, uint256) public pure override {
        revert SoulboundTransfer();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTransfer();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !_marketTransferInProgress) {
            revert SoulboundTransfer();
        }
        return super._update(to, tokenId, auth);
    }
}
