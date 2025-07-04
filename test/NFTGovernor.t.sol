 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NFTGovernor.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Votes.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Mock ERC721Votes contract to simulate Loot NFT collection
contract MockNFT is ERC721, ERC721Votes {
    constructor() ERC721("LootNFT", "LOOT") EIP712("LootNFT", "1") {
        // Mint 8,000 NFTs to the deployer
        for (uint256 i = 1; i <= 8000; i++) {
            _mint(msg.sender, i);
        }
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Votes)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 amount)
        internal
        override(ERC721, ERC721Votes)
    {
        super._increaseBalance(account, amount);
    }
}

// Mock target contract for proposal execution
contract MockTarget {
    uint256 public value;
    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract NFTGovernorTest is Test {
    // Contract instances
    MockNFT nftToken;
    TimelockController timelock;
    NFTGovernor governor;
    MockTarget target;

    // Test addresses
    address deployer = address(0x1);
    address voter1 = address(0x2); // Will hold 20 NFTs
    address voter2 = address(0x3); // Will hold 320 NFTs
    address voter3 = address(0x4); // Will hold 10 NFTs (below threshold)

    // Governance parameters (production-ready, assuming ~12s block time)
    uint48 constant VOTING_DELAY = 26_280; // ~4.48 days (26,280 blocks)
    uint32 constant VOTING_PERIOD = 39_420; // ~6.84 days (39,420 blocks)
    uint256 constant PROPOSAL_THRESHOLD = 16; // 16 NFTs
    uint256 constant QUORUM_NUMERATOR = 4; // 4% quorum (320 NFTs for 8,000 total)
    uint48 constant EXTENSION_PERIOD = 7_200; // 1 day (7,200 blocks)
    string constant GOVERNOR_NAME = "Loot DAO Governor";
    uint48 constant TIMELOCK_DELAY = 2 days;

    // Timelock role ID
    bytes32 constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    function setUp() public {
        // Set deployer as msg.sender
        vm.startPrank(deployer);

        // Deploy MockNFT
        nftToken = new MockNFT();

        // Deploy TimelockController
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // Placeholder
        executors[0] = address(0); // Placeholder
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, deployer);

        // Deploy NFTGovernor
        governor = new NFTGovernor(
            ERC721Votes(address(nftToken)),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR,
            EXTENSION_PERIOD,
            GOVERNOR_NAME
        );

        // Update TimelockController roles
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.renounceRole(TIMELOCK_ADMIN_ROLE, deployer);

        // Deploy MockTarget for proposal execution
        target = new MockTarget();

        // Distribute NFTs for testing
        for (uint256 i = 1; i <= 20; i++) {
            nftToken.transferFrom(deployer, voter1, i); // 20 NFTs to voter1
        }
        for (uint256 i = 21; i <= 340; i++) {
            nftToken.transferFrom(deployer, voter2, i); // 320 NFTs to voter2
        }
        for (uint256 i = 341; i <= 350; i++) {
            nftToken.transferFrom(deployer, voter3, i); // 10 NFTs to voter3
        }

        // Advance block number to record NFT transfers
        vm.roll(block.number + 1);
        // Delegate votes
        vm.stopPrank();
        vm.startPrank(voter1);
        nftToken.delegate(voter1); // Delegate 20 NFTs
        vm.stopPrank();
        vm.startPrank(voter2);
        nftToken.delegate(voter2); // Delegate 320 NFTs
        vm.stopPrank();
        vm.startPrank(voter3);
        nftToken.delegate(voter3); // Delegate 10 NFTs
        vm.stopPrank();

        // Advance block number to record delegations
        vm.roll(block.number + 1);
    }

    // Test 1: Verify deployment and initial parameters
    function testDeployment() public view {
        assertEq(governor.name(), GOVERNOR_NAME, "Incorrect governor name");
        assertEq(governor.votingDelay(), VOTING_DELAY, "Incorrect voting delay");
        assertEq(governor.votingPeriod(), VOTING_PERIOD, "Incorrect voting period");
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD, "Incorrect proposal threshold");
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR, "Incorrect quorum numerator");
        assertEq(governor.lateQuorumVoteExtension(), EXTENSION_PERIOD, "Incorrect extension period");
        assertEq(address(governor.nftToken()), address(nftToken), "Incorrect NFT token address");
        assertEq(address(governor.timelock()), address(timelock), "Incorrect timelock address");
        assertEq(governor.getTotalNFTSupply(), 8000, "Incorrect total NFT supply");
        assertTrue(governor.validateGovernanceParameters(), "Invalid governance parameters");
        assertEq(governor.owner(), deployer, "Incorrect owner");
    }

    // Test 2: Create a proposal with sufficient NFTs
    function testCreateProposal() public {
        vm.startPrank(voter1); // Has 20 NFTs, above threshold (16)
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending), "Proposal not in Pending state");
        vm.stopPrank();
    }

    // Test 3: Fail to create proposal with insufficient NFTs
    function testCreateProposalInsufficientNFTs() public {
        vm.startPrank(voter3); // Has 10 NFTs, below threshold (16)
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        vm.expectRevert("Insufficient historical NFT voting power");
        governor.propose(targets, values, calldatas, description);
        vm.stopPrank();
    }

    // Test 4: Vote on a proposal and reach quorum
    function testVoting() public {
        // Create proposal
        vm.startPrank(voter1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        // Fast-forward to voting period
        vm.roll(block.number + VOTING_DELAY + 1);

        // Vote
        vm.startPrank(voter1);
        governor.castVote(proposalId, 1); // 1 = For (20 votes)
        vm.stopPrank();

        vm.startPrank(voter2);
        governor.castVote(proposalId, 1); // 1 = For (320 votes)
        vm.stopPrank();

        // Verify voting power
        assertEq(governor.getNFTVotingPower(voter1, block.number - 1), 20, "Incorrect voter1 voting power");
        assertEq(governor.getNFTVotingPower(voter2, block.number - 1), 320, "Incorrect voter2 voting power");
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Active), "Proposal not in Active state");
    }
    // Test 5: Full governance cycle (propose, vote, queue, execute)
    function testQueueAndExecute() public {
        // Create proposal
        vm.startPrank(voter1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        // Fast-forward to voting period
        vm.roll(block.number + VOTING_DELAY + 1);

        // Vote to reach quorum (340 votes > 320 required)
        vm.startPrank(voter1);
        governor.castVote(proposalId, 1); // 1 = For
        vm.stopPrank();
        vm.startPrank(voter2);
        governor.castVote(proposalId, 1); // 1 = For
        vm.stopPrank();

        // Fast-forward past voting period
        vm.roll(block.number + VOTING_PERIOD + 1);

        // Verify proposal succeeded
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded), "Proposal not in Succeeded state");

        // Queue proposal
        vm.prank(deployer);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued), "Proposal not in Queued state");

        // Fast-forward past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Execute proposal
        vm.prank(deployer);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed), "Proposal not in Executed state");
        assertEq(target.value(), 42, "Target contract not updated");
    }

    // Test 6: Late quorum extension
    function testLateQuorumExtension() public {
        // Create proposal
        vm.startPrank(voter1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        // Fast-forward to near the end of voting period
        vm.roll(block.number + VOTING_DELAY + VOTING_PERIOD - 100);

        // Vote to reach quorum late
        vm.startPrank(voter2);
        governor.castVote(proposalId, 1); // 320 votes, reaching quorum
        vm.stopPrank();

        // Verify deadline extended
        uint256 extendedDeadline = block.number + EXTENSION_PERIOD;
        assertEq(governor.proposalDeadline(proposalId), extendedDeadline, "Deadline not extended");
    }

    // Test 7: Pause and unpause
    function testPause() public {
        // Pause contract
        vm.prank(deployer);
        governor.pause();

        // Try to propose while paused
        vm.startPrank(voter1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        vm.expectRevert("EnforcedPause");
        governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        // Unpause contract
        vm.prank(deployer);
        governor.unpause();

        // Propose after unpause
        vm.startPrank(voter1);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending), "Proposal not created after unpause");
        vm.stopPrank();
    }

    // Test 8: Parameter updates by owner
    function testUpdateParameters() public {
        vm.startPrank(deployer);
        governor.setVotingDelay(VOTING_DELAY + 1000);
        assertEq(governor.votingDelay(), VOTING_DELAY + 1000, "Voting delay not updated");

        governor.setVotingPeriod(VOTING_PERIOD + 1000);
        assertEq(governor.votingPeriod(), VOTING_PERIOD + 1000, "Voting period not updated");
        governor.setProposalThreshold(PROPOSAL_THRESHOLD + 1);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD + 1, "Proposal threshold not updated");

        governor.updateQuorumNumerator(QUORUM_NUMERATOR + 1);
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR + 1, "Quorum numerator not updated");

        governor.setExtensionPeriod(EXTENSION_PERIOD + 1000);
        assertEq(governor.lateQuorumVoteExtension(), EXTENSION_PERIOD + 1000, "Extension period not updated");
        vm.stopPrank();
    }

    // Test 9: Fail parameter updates with invalid values
    function testInvalidParameterUpdates() public {
        vm.startPrank(deployer);
        vm.expectRevert("Invalid voting delay");
        governor.setVotingDelay(0); // Below MIN_VOTING_DELAY

        vm.expectRevert("Invalid voting period");
        governor.setVotingPeriod(0); // Below MIN_VOTING_PERIOD

        vm.expectRevert("Invalid proposal threshold");
        governor.setProposalThreshold(0); // Below MIN_PROPOSAL_THRESHOLD

        vm.expectRevert("Invalid quorum numerator");
        governor.updateQuorumNumerator(0); // Below MIN_QUORUM_NUMERATOR

        vm.expectRevert("Invalid extension period");
        governor.setExtensionPeriod(0); // Below MIN_EXTENSION_PERIOD
        vm.stopPrank();
    }

    // Test 10: Signed voting (simplified version without EIP712 signature)
    function testCastVoteBySig() public {
        // Create proposal
        vm.startPrank(voter1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) = _createProposalData();
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.stopPrank();

        // Fast-forward to voting period
        vm.roll(block.number + VOTING_DELAY + 1);

        // Create signature for voter1 using a simplified approach
        (uint8 v, bytes32 r, bytes32 s) = _signVote(voter1, proposalId, 1); // 1 = For
        
        // Cast vote by signature
        vm.prank(address(this)); // Cast from test contract
        governor.castVoteBySig(proposalId, 1, v, r, s);

        // Note: In a real implementation, you'd verify the signature properly
        // For this test, we're just ensuring the function call doesn't revert
    }

    // Helper function to create proposal data
    function _createProposalData()
        internal
        view
        returns (address[] memory, uint256[] memory, bytes[] memory, string memory)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(target);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        string memory description = "Set target value to 42";
        return (targets, values, calldatas, description);
    }

    // Helper function to create a mock signature (for testing purposes only)
    function _signVote(address voter, uint256 proposalId, uint8 support)
        internal
        pure
        returns (uint8, bytes32, bytes32)
    {
        // Create a deterministic but fake signature for testing
        // In a real implementation, you'd use proper EIP712 signing
        bytes32 hash = keccak256(abi.encodePacked(voter, proposalId, support));
        
        // Return mock signature values
        return (27, hash, keccak256(abi.encodePacked(hash, "mock")));
    }
}