// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorPreventLateQuorum.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Votes.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title SecureTallyNFTGovernor
 * @dev A secure OpenZeppelin Governor contract for NFT-based governance, fully compatible with Tally.xyz
 * Designed for NFT collections like Loot where 1 NFT = 1 Vote
 *
 * Features:
 * - NFT-based voting (ERC721Votes compatible)
 * - Owner-only parameter updates with security checks
 * - Full Tally compatibility (events, functions, states)
 * - Anti-late quorum protection
 * - Timelock integration
 * - Pausable for emergency situations
 * - Reentrancy protection
 */
contract NFTGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    GovernorPreventLateQuorum,
    Ownable,
    ReentrancyGuard,
    Pausable
{
    // Security constants - adjusted for NFT governance
    uint48 public constant MIN_VOTING_DELAY = 1 minutes;
    uint48 public constant MAX_VOTING_DELAY = 30 days;
    uint32 public constant MIN_VOTING_PERIOD = 1 minutes;
    uint32 public constant MAX_VOTING_PERIOD = 60 days;
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 1; // 1 NFT minimum
    uint256 public constant MAX_PROPOSAL_THRESHOLD = 100; // 100 NFTs max
    uint256 public constant MIN_QUORUM_NUMERATOR = 1; // 1% of NFT supply minimum
    uint256 public constant MAX_QUORUM_NUMERATOR = 50; // 50% of NFT supply maximum
    uint48 public constant MIN_EXTENSION_PERIOD = 1 hours;
    uint48 public constant MAX_EXTENSION_PERIOD = 7 days;

    // NFT collection reference
    ERC721Votes public immutable nftToken;

    // Events for Tally compatibility
    event ExtensionPeriodUpdated(uint256 oldExtensionPeriod, uint256 newExtensionPeriod);

    constructor(
        ERC721Votes _nftToken,
        TimelockController _timelock,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumeratorValue,
        uint48 _extensionPeriod,
        string memory _governorName
    )
        Governor(_governorName)
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorVotes(IVotes(address(_nftToken)))
        GovernorVotesQuorumFraction(_quorumNumeratorValue)
        GovernorTimelockControl(_timelock)
        GovernorPreventLateQuorum(_extensionPeriod)
        Ownable(msg.sender)
    {
        require(address(_nftToken) != address(0), "NFT token cannot be zero address");
        require(address(_timelock) != address(0), "Timelock cannot be zero address");
        require(_votingDelay >= MIN_VOTING_DELAY && _votingDelay <= MAX_VOTING_DELAY, "Invalid voting delay");
        require(_votingPeriod >= MIN_VOTING_PERIOD && _votingPeriod <= MAX_VOTING_PERIOD, "Invalid voting period");
        require(_proposalThreshold >= MIN_PROPOSAL_THRESHOLD && _proposalThreshold <= MAX_PROPOSAL_THRESHOLD, "Invalid proposal threshold");
        require(_quorumNumeratorValue >= MIN_QUORUM_NUMERATOR && _quorumNumeratorValue <= MAX_QUORUM_NUMERATOR, "Invalid quorum numerator");
        require(_extensionPeriod >= MIN_EXTENSION_PERIOD && _extensionPeriod <= MAX_EXTENSION_PERIOD, "Invalid extension period");

        nftToken = _nftToken;
    }

    // ============ NFT-SPECIFIC FUNCTIONS ============

    function getTotalNFTSupply() public view returns (uint256) {
        return block.number > 0 ? nftToken.getPastTotalSupply(block.number - 1) : nftToken.getPastTotalSupply(0);
    }

    function getNFTVotingPower(address account, uint256 timepoint) public view returns (uint256) {
        return nftToken.getPastVotes(account, timepoint);
    }

    function getCurrentNFTVotingPower(address account) public view returns (uint256) {
        return nftToken.getVotes(account);
    }

    // ============ OWNER-ONLY PARAMETER UPDATES ============

    function setVotingDelay(uint48 newVotingDelay) public override onlyOwner {
        require(newVotingDelay >= MIN_VOTING_DELAY && newVotingDelay <= MAX_VOTING_DELAY, "Invalid voting delay");
        uint256 oldVotingDelay = votingDelay();
        require(newVotingDelay != oldVotingDelay, "Same voting delay");
        _setVotingDelay(newVotingDelay);
    }

    function setVotingPeriod(uint32 newVotingPeriod) public override onlyOwner {
        require(newVotingPeriod >= MIN_VOTING_PERIOD && newVotingPeriod <= MAX_VOTING_PERIOD, "Invalid voting period");
        uint256 oldVotingPeriod = votingPeriod();
        require(newVotingPeriod != oldVotingPeriod, "Same voting period");
        _setVotingPeriod(newVotingPeriod);
    }

    function setProposalThreshold(uint256 newProposalThreshold) public override onlyOwner {
        require(newProposalThreshold >= MIN_PROPOSAL_THRESHOLD && newProposalThreshold <= MAX_PROPOSAL_THRESHOLD, "Invalid proposal threshold");
        uint256 oldProposalThreshold = proposalThreshold();
        require(newProposalThreshold != oldProposalThreshold, "Same proposal threshold");
        _setProposalThreshold(newProposalThreshold);
    }

    function updateQuorumNumerator(uint256 newQuorumNumerator) public override onlyOwner {
        require(newQuorumNumerator >= MIN_QUORUM_NUMERATOR && newQuorumNumerator <= MAX_QUORUM_NUMERATOR, "Invalid quorum numerator");
        uint256 oldQuorumNumerator = quorumNumerator();
        require(newQuorumNumerator != oldQuorumNumerator, "Same quorum numerator");
        _updateQuorumNumerator(newQuorumNumerator);
    }

    function setExtensionPeriod(uint48 newExtensionPeriod) external onlyOwner {
        require(newExtensionPeriod >= MIN_EXTENSION_PERIOD && newExtensionPeriod <= MAX_EXTENSION_PERIOD, "Invalid extension period");
        uint256 oldExtensionPeriod = lateQuorumVoteExtension();
        require(newExtensionPeriod != oldExtensionPeriod, "Same extension period");
        _setLateQuorumVoteExtension(newExtensionPeriod);
        emit ExtensionPeriodUpdated(oldExtensionPeriod, newExtensionPeriod);
    }

    // ============ EMERGENCY FUNCTIONS ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ OVERRIDES FOR TALLY COMPATIBILITY ============

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 snapshotBlock;
        
        if (block.number == 0) {
            require(nftToken.getVotes(_msgSender()) >= proposalThreshold(), "Insufficient NFT voting power at genesis");
            snapshotBlock = 0;
        } else {
            snapshotBlock = block.number - 1;
            require(nftToken.getPastVotes(_msgSender(), snapshotBlock) >= proposalThreshold(), "Insufficient historical NFT voting power");
        }
        return super.propose(targets, values, calldatas, description);
    }

    function castVote(uint256 proposalId, uint8 support) public override whenNotPaused nonReentrant returns (uint256) {
        return super.castVote(proposalId, support);
    }

    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public override whenNotPaused nonReentrant returns (uint256) {
        return super.castVoteWithReason(proposalId, support, reason);
    }

    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public whenNotPaused nonReentrant returns (uint256) {
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes32 structHash = keccak256(abi.encode(keccak256("Ballot(uint256 proposalId,uint8 support)"), proposalId, support));
        bytes32 hash = _hashTypedDataV4(structHash);
        address voter = ECDSA.recover(hash, signature);
        return super.castVoteBySig(proposalId, support, voter, signature);
    }

    // ============ REQUIRED OVERRIDES ============

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalDeadline(uint256 proposalId) public view override(Governor, GovernorPreventLateQuorum) returns (uint256) {
        return super.proposalDeadline(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function _tallyUpdated(uint256 proposalId) internal override(Governor, GovernorPreventLateQuorum) {
        super._tallyUpdated(proposalId);
    }

    // ============ VIEW FUNCTIONS FOR TRANSPARENCY ============

    function getGovernanceParameters() external view returns (
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator,
        uint256 _quorumDenominator,
        uint256 _extensionPeriod,
        address _timelock,
        address _nftToken,
        uint256 _totalNFTSupply
    ) {
        return (
            votingDelay(),
            votingPeriod(),
            proposalThreshold(),
            quorumNumerator(),
            quorumDenominator(),
            lateQuorumVoteExtension(),
            address(timelock()),
            address(nftToken),
            getTotalNFTSupply()
        );
    }

    function getNFTGovernanceStats() external view returns (
        uint256 totalNFTs,
        uint256 currentQuorumRequired,
        uint256 proposalThresholdNFTs
    ) {
        uint256 totalSupply = getTotalNFTSupply();
        return (totalSupply, quorum(block.number - 1), proposalThreshold());
    }

    function validateGovernanceParameters() external view returns (bool) {
        uint256 _votingDelay = votingDelay();
        uint256 _votingPeriod = votingPeriod();
        uint256 _proposalThreshold = proposalThreshold();
        uint256 _quorumNumerator = quorumNumerator();
        uint256 _extensionPeriod = lateQuorumVoteExtension();

        return (_votingDelay >= MIN_VOTING_DELAY &&
            _votingDelay <= MAX_VOTING_DELAY &&
            _votingPeriod >= MIN_VOTING_PERIOD &&
            _votingPeriod <= MAX_VOTING_PERIOD &&
            _proposalThreshold >= MIN_PROPOSAL_THRESHOLD &&
            _proposalThreshold <= MAX_PROPOSAL_THRESHOLD &&
            _quorumNumerator >= MIN_QUORUM_NUMERATOR &&
            _quorumNumerator <= MAX_QUORUM_NUMERATOR &&
            _extensionPeriod >= MIN_EXTENSION_PERIOD &&
            _extensionPeriod <= MAX_EXTENSION_PERIOD);
    }

    function canCreateProposal(address account) external view returns (bool) {
        return getCurrentNFTVotingPower(account) >= proposalThreshold();
    }
}