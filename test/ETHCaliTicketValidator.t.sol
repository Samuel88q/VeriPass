// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ETHCaliTicketValidator} from "../src/ETHCaliTicketValidator.sol";

contract ETHCaliTicketValidatorTest is Test {
    ETHCaliTicketValidator private validator;
    address private issuer = makeAddr("issuer");
    address private attendee = makeAddr("attendee");
    address private anotherAttendee = makeAddr("anotherAttendee");
    bytes32 private constant TICKET_HASH = keccak256("ticket-001");

    function setUp() public {
        vm.prank(issuer);
        validator = new ETHCaliTicketValidator();
    }

    function testIssueTicketStoresProofAndMetadata() public {
        vm.prank(issuer);
        uint256 tokenId = validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");

        assertEq(tokenId, 1);
        assertEq(validator.ownerOf(tokenId), attendee);
        assertEq(validator.tokenIdForHash(TICKET_HASH), tokenId);
        assertEq(validator.ticketHash(tokenId), TICKET_HASH);
        assertEq(validator.tokenURI(tokenId), "ipfs://ticket-001");
    }

    function testMintAndConsumeTicket() public {
        vm.prank(issuer);
        uint256 tokenId = validator.mintTicket(attendee);

        assertEq(validator.ownerOf(tokenId), attendee);
        assertFalse(validator.consumed(tokenId));

        vm.prank(issuer);
        validator.consumeTicket(tokenId);

        assertTrue(validator.consumed(tokenId));
        assertEq(validator.ownerOf(tokenId), attendee);

        vm.prank(issuer);
        vm.expectRevert(ETHCaliTicketValidator.TicketAlreadyConsumed.selector);
        validator.consumeTicket(tokenId);
    }

    function testMintAndConsumeAreOwnerOnly() public {
        vm.prank(attendee);
        vm.expectRevert();
        validator.mintTicket(attendee);

        vm.prank(issuer);
        uint256 tokenId = validator.mintTicket(attendee);

        vm.prank(attendee);
        vm.expectRevert();
        validator.consumeTicket(tokenId);
    }

    function testOnlyIssuerCanIssueAndRevoke() public {
        vm.prank(attendee);
        vm.expectRevert();
        validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");

        vm.prank(issuer);
        uint256 tokenId = validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");

        vm.prank(attendee);
        vm.expectRevert();
        validator.revokeTicket(tokenId);
    }

    function testRejectsInvalidAndDuplicateTickets() public {
        vm.startPrank(issuer);
        vm.expectRevert(ETHCaliTicketValidator.InvalidRecipient.selector);
        validator.issueTicket(address(0), TICKET_HASH, "");

        vm.expectRevert(ETHCaliTicketValidator.InvalidTicketHash.selector);
        validator.issueTicket(attendee, bytes32(0), "");

        validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");
        vm.expectRevert(ETHCaliTicketValidator.TicketAlreadyIssued.selector);
        validator.issueTicket(anotherAttendee, TICKET_HASH, "ipfs://duplicate");
        vm.stopPrank();
    }

    function testAllTransferAndApprovalRoutesAreBlocked() public {
        vm.prank(issuer);
        uint256 tokenId = validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");

        vm.startPrank(attendee);
        vm.expectRevert(ETHCaliTicketValidator.SoulboundTransfer.selector);
        validator.transferFrom(attendee, anotherAttendee, tokenId);
        vm.expectRevert(ETHCaliTicketValidator.SoulboundTransfer.selector);
        validator.safeTransferFrom(attendee, anotherAttendee, tokenId);
        vm.expectRevert(ETHCaliTicketValidator.SoulboundTransfer.selector);
        validator.safeTransferFrom(attendee, anotherAttendee, tokenId, "");
        vm.expectRevert(ETHCaliTicketValidator.SoulboundTransfer.selector);
        validator.approve(anotherAttendee, tokenId);
        vm.expectRevert(ETHCaliTicketValidator.SoulboundTransfer.selector);
        validator.setApprovalForAll(anotherAttendee, true);
        vm.stopPrank();
    }

    function testListedTicketCanOnlyMoveThroughExactPricePurchase() public {
        uint256 price = 1 ether;

        vm.prank(issuer);
        uint256 tokenId = validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");

        vm.prank(attendee);
        validator.listTicket(tokenId, price);
        assertEq(validator.ticketPrices(tokenId), price);

        vm.startPrank(attendee);
        vm.expectRevert(ETHCaliTicketValidator.SoulboundTransfer.selector);
        validator.transferFrom(attendee, anotherAttendee, tokenId);
        vm.stopPrank();

        vm.deal(anotherAttendee, price);
        uint256 sellerBalanceBefore = attendee.balance;
        vm.prank(anotherAttendee);
        validator.buyTicket{value: price}(tokenId);

        assertEq(validator.ownerOf(tokenId), anotherAttendee);
        assertEq(validator.ticketPrices(tokenId), 0);
        assertEq(attendee.balance, sellerBalanceBefore + (price * 90) / 100);
        assertEq(address(validator).balance, (price * 10) / 100);
    }

    function testBuyTicketRejectsIncorrectPaymentAndConsumedTickets() public {
        uint256 price = 1 ether;

        vm.prank(issuer);
        uint256 tokenId = validator.mintTicket(attendee);
        vm.prank(attendee);
        validator.listTicket(tokenId, price);

        vm.deal(anotherAttendee, price);
        vm.prank(anotherAttendee);
        vm.expectRevert(ETHCaliTicketValidator.IncorrectPayment.selector);
        validator.buyTicket{value: price - 1}(tokenId);

        vm.prank(issuer);
        validator.consumeTicket(tokenId);
        assertEq(validator.ticketPrices(tokenId), 0);

        vm.prank(anotherAttendee);
        vm.expectRevert(ETHCaliTicketValidator.TicketAlreadyConsumed.selector);
        validator.buyTicket{value: price}(tokenId);
    }

    function testIssuerCanRevokeAndReuseHash() public {
        vm.prank(issuer);
        uint256 tokenId = validator.issueTicket(attendee, TICKET_HASH, "ipfs://ticket-001");

        vm.prank(issuer);
        validator.revokeTicket(tokenId);
        assertEq(validator.tokenIdForHash(TICKET_HASH), 0);

        vm.prank(issuer);
        uint256 replacementTokenId = validator.issueTicket(anotherAttendee, TICKET_HASH, "ipfs://ticket-001-v2");
        assertEq(replacementTokenId, 2);
        assertEq(validator.ownerOf(replacementTokenId), anotherAttendee);
    }
}
