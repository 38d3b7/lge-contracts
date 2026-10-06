// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {SafeNativeSender} from "./utils/SafeNativeSender.sol";

interface IAgentSource {
    function agent() external view returns (address);
}

contract InferenceEscrow is SafeNativeSender {
    address public immutable owner;

    address public provider;
    address public proposedProvider;
    uint64 public providerEffectiveAt;

    uint256 public gasCap; // max per fundGas call
    uint256 public gasBudget; // lifetime fundGas ceiling per hook
    bool public gasBudgetSet;

    /// @dev hook => native USDC credit (18 decimals)
    mapping(address => uint256) public creditOf;
    /// @dev hook => cumulative native USDC drawn through fundGas. Keyed by
    ///      hook, not agent, so rotating the agent cannot reset the budget.
    mapping(address => uint256) public totalGasFunded;

    uint64 public constant PROVIDER_TIMELOCK = 48 hours;

    event Credited(address indexed hook, uint256 amount);
    event ProviderPaid(address indexed hook, address indexed agent, uint256 amount);
    event GasFunded(address indexed hook, address indexed agent, uint256 amount);
    event ProviderProposed(address indexed provider, uint64 effectiveAt);
    event ProviderSet(address indexed provider);
    event GasCapSet(uint256 cap);
    event GasBudgetSet(uint256 budget);

    error NotOwner();
    error NotAgent();
    error ProviderAlreadySet();
    error ProviderNotSet();
    error TimelockNotElapsed();
    error NoProposal();
    error InsufficientCredit();
    error GasCapExceeded();
    error GasBudgetExceeded();
    error GasBudgetIncrease();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        owner = owner_;
    }

    function credit() external payable {
        creditOf[msg.sender] += msg.value;
        emit Credited(msg.sender, msg.value);
    }

    function payProvider(address hook, uint256 amount) external {
        if (provider == address(0)) revert ProviderNotSet();
        _spend(hook, amount);
        _sendNative(provider, amount);
        emit ProviderPaid(hook, msg.sender, amount);
    }

    function fundGas(address hook, uint256 amount) external {
        if (amount > gasCap) revert GasCapExceeded();
        if (totalGasFunded[hook] + amount > gasBudget) revert GasBudgetExceeded();
        totalGasFunded[hook] += amount;
        _spend(hook, amount);
        _sendNative(msg.sender, amount);
        emit GasFunded(hook, msg.sender, amount);
    }

    function _spend(address hook, uint256 amount) internal {
        if (IAgentSource(hook).agent() != msg.sender) revert NotAgent();
        if (creditOf[hook] < amount) revert InsufficientCredit();
        creditOf[hook] -= amount;
    }

    function proposeProvider(address provider_) external onlyOwner {
        if (provider != address(0)) revert ProviderAlreadySet();
        proposedProvider = provider_;
        providerEffectiveAt = uint64(block.timestamp) + PROVIDER_TIMELOCK;
        emit ProviderProposed(provider_, providerEffectiveAt);
    }

    function applyProvider() external onlyOwner {
        if (provider != address(0)) revert ProviderAlreadySet();
        if (proposedProvider == address(0)) revert NoProposal();
        if (block.timestamp < providerEffectiveAt) revert TimelockNotElapsed();
        provider = proposedProvider;
        proposedProvider = address(0);
        emit ProviderSet(provider);
    }

    function setGasCap(uint256 cap) external onlyOwner {
        gasCap = cap;
        emit GasCapSet(cap);
    }

    function setGasBudget(uint256 budget) external onlyOwner {
        if (gasBudgetSet && budget > gasBudget) revert GasBudgetIncrease();
        gasBudgetSet = true;
        gasBudget = budget;
        emit GasBudgetSet(budget);
    }
}
