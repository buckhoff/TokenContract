// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

library Constants{
    // Constants for contract names (can be in a shared Constants.sol file)
    bytes32 internal constant TOKEN_NAME = keccak256("_TEACH_TOKEN");
    bytes32 internal constant STABILITY_FUND_NAME = keccak256("PLATFORM_STABILITY_FUND");
    bytes32 internal constant STAKING_NAME = keccak256("TOKEN_STAKING");
    bytes32 internal constant GOVERNANCE_NAME = keccak256("PLATFORM_GOVERNANCE");
    bytes32 internal constant MARKETPLACE_NAME = keccak256("PLATFORM_MARKETPLACE");
    bytes32 internal constant PLATFORM_REWARD_NAME = keccak256("PLATFORM_REWARD");
    bytes32 internal constant CROWDSALE_NAME = keccak256("TOKEN_CROWDSALE");

    //Role constants
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 internal constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant RECORDER_ROLE = keccak256("RECORDER_ROLE");
    bytes32 internal constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 internal constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
}
