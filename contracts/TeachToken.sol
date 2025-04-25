// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

/**
 * @title TeachToken
 * @dev Implementation of the TEACH Token for the TeacherSupport Platform on Polygon
 */
contract TeachToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    RegistryAwareUpgradeable
{

    ERC20Upgradeable internal token;
    
    // Maximum supply cap
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 10**18; // 5 billion tokens

    // Track if initial distribution has been performed
    bool private initialDistributionDone;

    // Recovery mechanism for accidentally sent tokens
    mapping(address => bool) public recoveryAllowedTokens;

    bool internal paused;
    bool public inEmergencyRecovery;
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;

    // Events
    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);
    event BurnerAdded(address indexed account);
    event BurnerRemoved(address indexed account);
    event TokensBurned(address indexed burner, uint256 amount);
    event InitialDistributionComplete(uint256 timestamp);
    event RecoveryTokenStatusChanged(address indexed token, bool allowed);
    event ERC20TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event RegistrySet(address indexed registry);
    event BurnNotificationSent(uint256 amount);
    event BurnNotificationFailed(uint256 amount, string reason);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin);

    modifier whenContractNotPaused() {
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "TeachToken: system is paused");
            } catch {
                // If registry call fails, fall back to local pause state
                require(!paused, "TeachToken: contract is paused");
            }
            require(registry.isRegistryOffline() = false, "TeachToken: registry Offline");
        } else {
            require(!paused, "TeachToken: contract is paused");
        }
        _;
    }    
    
    /**
     * @dev Constructor that initializes the token with name, symbol, and roles
     */
    constructor() {
        _disableInitializers();
    }

    /**
    * @dev Initializes the contract replacing the constructor
     */
    function initialize() initializer public {
        __ERC20_init("TeacherSupport Token", "TEACH");
        __ERC20Burnable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.MINTER_ROLE, msg.sender);
        _grantRole(Constants.BURNER_ROLE, msg.sender);
        initialDistributionDone = false;
        requiredRecoveryApprovals = 3;
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRegistry(_registry, Constants.TOKEN_NAME);
        emit RegistrySet(_registry);
    }
    
    /**
    * @dev Performs the initial token distribution according to the defined allocation
    * Can only be called once by the admin
    */
    function performInitialDistribution(
        address platformEcosystemAddress,
        address communityIncentivesAddress,
        address initialLiquidityAddress,
        address publicPresaleAddress,
        address teamAndDevAddress,
        address educationalPartnersAddress,
        address reserveAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!initialDistributionDone, "Initial distribution already completed");
        require(platformEcosystemAddress != address(0), "Zero address for platformEcosystem");
        require(communityIncentivesAddress != address(0), "Zero address for communityIncentives");
        require(initialLiquidityAddress != address(0), "Zero address for initialLiquidity");
        require(publicPresaleAddress != address(0), "Zero address for publicPresale");
        require(teamAndDevAddress != address(0), "Zero address for teamAndDev");
        require(educationalPartnersAddress != address(0), "Zero address for educationalPartners");
        require(reserveAddress != address(0), "Zero address for reserve");

        require(
            platformEcosystemAddress != communityIncentivesAddress &&
            platformEcosystemAddress != initialLiquidityAddress &&
            platformEcosystemAddress != publicPresaleAddress &&
            educationalPartnersAddress != reserveAddress,
            "Duplicate addresses not allowed"
        );
        
        // Define allocation amounts
        uint256 platformEcosystemAmount = 1_600_000_000 * 10**18; // 32%
        uint256 communityIncentivesAmount = 1_100_000_000 * 10**18; // 22%
        uint256 initialLiquidityAmount = 700_000_000 * 10**18; // 14%
        uint256 publicPresaleAmount = 500_000_000 * 10**18; // 10%
        uint256 teamAndDevAmount = 500_000_000 * 10**18; // 10%
        uint256 educationalPartnersAmount = 400_000_000 * 10**18; // 8%
        uint256 reserveAmount = 200_000_000 * 10**18; // 4%

        // Validate that the sum of all allocations equals MAX_SUPPLY
        uint256 totalAllocation = platformEcosystemAmount + communityIncentivesAmount +
                    initialLiquidityAmount + publicPresaleAmount +
                    teamAndDevAmount + educationalPartnersAmount +
                    reserveAmount;

        require(totalAllocation == MAX_SUPPLY, "Total allocation must equal MAX_SUPPLY");

        // Platform Ecosystem (32%)
        _mint(platformEcosystemAddress, platformEcosystemAmount);

        // Community Incentives (22%)
        _mint(communityIncentivesAddress, communityIncentivesAmount);

        // Initial Liquidity (14%)
        _mint(initialLiquidityAddress, initialLiquidityAmount);

        // Public Presale (10%)
        _mint(publicPresaleAddress, publicPresaleAmount);

        // Team and Development (10%)
        _mint(teamAndDevAddress, teamAndDevAmount);

        // Educational Partners (8%)
        _mint(educationalPartnersAddress, educationalPartnersAmount);

        // Reserve (4%)
        _mint(reserveAddress, reserveAmount);

        initialDistributionDone = true;
        emit InitialDistributionComplete(block.timestamp);
    }
    
    /**
     * @dev Pauses all token transfers
     * Requirements: Caller must have the ADMIN_ROLE
     */
    function pause() public {
        
        if (address(registry) != address(0) && registry.isContractActive(Constants.TOKEN_NAME)){
            require(
                hasRole(Constants.ADMIN_ROLE, msg.sender),
                "TeachToken: not authorized"
            );
            paused=true;
        }
        else {
            require(hasRole(Constants.ADMIN_ROLE, msg.sender), "TeachToken: not authorized");
        }
    }

    /**
     * @dev Unpauses all token transfers
     * Requirements: Caller must have the ADMIN_ROLE
     */
    function unpause() public onlyRole(Constants.EMERGENCY_ROLE) {
        // Check if system is still paused before unpausing locally
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                require(!systemPaused, "TokenStaking: system still paused");
            } catch {
                // If registry call fails, proceed with unpause
            }
        }

        paused = false;
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     * Requirements: Caller must have the MINTER_ROLE
     * Total supply must not exceed MAX_SUPPLY
     */
    function mint(address to, uint256 amount) public onlyRole(Constants.MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "TeachToken: Max supply exceeded");
        _mint(to, amount);
    }

    /**
    * @dev Override burn function to add stability fund notification
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) public override nonReentrant whenContractNotPaused {
        super.burn(amount);

        // Notify stability fund about the burn if registry is set
        _notifyBurn(amount);

        emit TokensBurned(_msgSender(), amount);
    }
    
    /**
     * @dev Burns tokens from a specified address
     * Can only be called by an account with BURNER_ROLE
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyRole(Constants.BURNER_ROLE) nonReentrant whenContractNotPaused {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);

        _notifyBurn(amount);
        
        emit TokensBurned(from, amount);
    }

    /**
     * @dev Burn with deflationary effect notification to stability fund
     * @param amount Amount burned
     */
    function _notifyBurn(uint256 amount) internal {

        if (address(registry) != address(0)) {
            bytes32 stabilityFundName = "PLATFORM_STABILITY_FUND";
            
            try registry.isContractActive(stabilityFundName) returns (bool isActive) {
                if (isActive) {
                    
                    try registry.getContractAddress(stabilityFundName) returns (address stabilityFund) {
                        // Create the calldata
                        bytes memory callData = abi.encodeWithSignature(
                            "processBurnedTokens(uint256)",
                            amount
                        );
                        // Call the stability fund's processBurnedTokens function
                        (bool success, ) = _safeContractCall(stabilityFundName, callData);
                        
                        // We don't revert if this call fails to maintain the primary burn functionality
                        if (success) {
                            emit BurnNotificationSent(amount);
                        } else {
                            emit BurnNotificationFailed(amount, "Call to stability fund failed");
                        }
                    } catch {
                        emit BurnNotificationFailed(amount, "Failed to get stability fund address");
                    }
                }
            } catch{
                emit BurnNotificationFailed(amount, "Failed to check stability fund status");
            }
        }
    }
    
    /**
     * @dev Adds a new minter with rights to mint tokens
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function addMinter(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(Constants.MINTER_ROLE, account);
        emit MinterAdded(account);
    }

    /**
     * @dev Removes a minter
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function removeMinter(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(Constants.MINTER_ROLE, account);
        emit MinterRemoved(account);
    }

    /**
     * @dev Adds a new burner with rights to burn tokens
     * @param account Address to be granted the burner role
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function addBurner(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(Constants.BURNER_ROLE, account);
        emit BurnerAdded(account);
    }

    /**
     * @dev Removes a burner
     * @param account Address to have the burner role revoked
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function removeBurner(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(Constants.BURNER_ROLE, account);
        emit BurnerRemoved(account);
    }
    
    /**
     * @dev Hook that is called before any transfer of tokens.
     * Prevents transfers when the contract is paused.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenContractNotPaused
    {
        // Also check if system is paused via registry
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool paused) {
                require(!paused, "TeachToken: system is paused");
            } catch {
                // If registry call fails, continue with the transfer
                // This prevents tokens being locked if the registry is compromised
            }
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Returns the chain ID of the current blockchain.
     * @return chainId of the current blockchain
     */
    function getChainId() public view returns (uint256) {
        return block.chainid;
    }

    /**
     * @dev Check if the initial distribution has been completed
     * @return Boolean indicating if initial distribution is done
     */
    function isInitialDistributionComplete() public view returns (bool) {
        return initialDistributionDone;
    }

    /**
     * @dev Set whether a token is allowed to be recovered
     * @param _token Address of the token
     * @param _allowed Whether recovery is allowed
     */
    function setRecoveryAllowedToken(address _token, bool _allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_token != address(0), "TeachToken: zero token address");
        require(_token != address(this), "TeachToken: cannot allow TEACH token");

        recoveryAllowedTokens[_token] = _allowed;

        emit RecoveryTokenStatusChanged(_token, _allowed);
    }
    
    /**
    * @dev Allows the admin to recover tokens accidentally sent to the contract
    * @param tokenAddress The address of the token to recover
    * @param amount The amount of tokens to recover
    */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(tokenAddress != address(this), "TeachToken: Cannot recover TEACH tokens");
        require(amount > 0, "TeachToken: Zero amount");
        require(recoveryAllowedTokens[tokenAddress], "TeachToken: Token recovery not allowed");

        token = ERC20Upgradeable(tokenAddress);
        require(token.balanceOf(address(this)) >= amount, "TeachToken: Insufficient balance");

        bool success = token.transfer(msg.sender, amount);
        require(success, "TeachToken: Transfer failed");

        emit ERC20TokensRecovered(tokenAddress, msg.sender, amount);
    }

    // Add emergency recovery functions
    function initiateEmergencyRecovery() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(paused(), "Token: not paused");
        inEmergencyRecovery = true;
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        require(inEmergencyRecovery, "Token: not in recovery mode");
        require(!emergencyRecoveryApprovals[msg.sender], "Token: already approved");

        emergencyRecoveryApprovals[msg.sender] = true;

        if (_countRecoveryApprovals() >= requiredRecoveryApprovals) {
            inEmergencyRecovery = false;
            _unpause();
            emit EmergencyRecoveryCompleted(msg.sender);
        }
    }

    function _countRecoveryApprovals() internal view returns (uint256) {
        uint256 count = 0;
        uint256 memberCount = getRoleMemberCount(Constants.ADMIN_ROLE);
        for (uint i = 0; i < memberCount; i++) {
            address admin = getRoleMember(Constants.ADMIN_ROLE, i);
            if (emergencyRecoveryApprovals[admin]) {
                count++;
            }
        }
        return count;
    }

    // Update cache periodically
    function updateAddressCache() public {
        if (address(registry) != address(0)) {
            try registry.getContractAddress(Constants.TOKEN_NAME) returns (address tokenAddress) {
                if (tokenAddress != address(0)) {
                    _cachedTokenAddress = tokenAddress;
                }
            } catch {}

            try registry.getContractAddress(Constants.STABILITY_FUND_NAME) returns (address stabilityFund) {
                if (stabilityFund != address(0)) {
                    _cachedStabilityFundAddress = stabilityFund;
                }
            } catch {}

            _lastCacheUpdate = block.timestamp;
        }
    }

    /**
     * @dev Retrieves the address of the PLATFORM STABILITY FUND contract, with fallback mechanisms
     * @return The address of the token contract
     */
    function getStabilityAddressWithFallback() internal returns (address) {
        // First attempt: Try registry lookup
        if (address(registry) != address(0) && !registryOfflineMode) {
            try registry.getContractAddress(Constants.PLATFORM_STABILITY_FUND) returns (address stabilityFundAddress) {
                if (stabilityFundAddress != address(0)) {
                    // Update cache with successful lookup
                    _cachedStabilityFundAddress = stabilityFundAddress;
                    _lastCacheUpdate = block.timestamp;
                    return stabilityFundAddress;
                }
            } catch {
                // Registry lookup failed, continue to fallbacks
            }
        }

        // Second attempt: Use cached address if available and not too old
        if (_cachedStabilityFundAddress != address(0) && block.timestamp - _lastCacheUpdate < 1 days) {
            return _cachedStabilityFundAddress;
        }

        // Third attempt: Use explicitly set fallback address
        address fallbackAddress = _fallbackAddresses[Constants.PLATFORM_STABILITY_FUND];
        if (fallbackAddress != address(0)) {
            return fallbackAddress;
        }

        // Final fallback: Use hardcoded address (if appropriate) or revert
        revert("Stability Fund address unavailable through all fallback mechanisms");
    }

    /**
     * @dev Retrieves the address of the Token contract, with fallback mechanisms
     * @return The address of the token contract
     */
    function getTokenAddressWithFallback() internal returns (address) {
        // First attempt: Try registry lookup
        if (address(registry) != address(0) && !registryOfflineMode) {
            try registry.getContractAddress(Constants.TOKEN_NAME) returns (address tokenAddress) {
                if (tokenAddress != address(0)) {
                    // Update cache with successful lookup
                    _cachedTokenAddress = tokenAddress;
                    _lastCacheUpdate = block.timestamp;
                    return tokenAddress;
                }
            } catch {
                // Registry lookup failed, continue to fallbacks
            }
        }

        // Second attempt: Use cached address if available and not too old
        if (_cachedTokenAddress != address(0) && block.timestamp - _lastCacheUpdate < 1 days) {
            return _cachedTokenAddress;
        }

        // Third attempt: Use explicitly set fallback address
        address fallbackAddress = _fallbackAddresses[Constants.TOKEN_NAME];
        if (fallbackAddress != address(0)) {
            return fallbackAddress;
        }

        // Final fallback: Use this contract's address as last resort
        // This is safer than reverting when used in critical paths
        return address(this);
    }

    function getRoleMemberCount(bytes32 role) internal view returns (uint256) {
        return AccessControlUpgradeable.getRoleMemberCount(role);
    }

    function getRoleMember(bytes32 role, uint256 index) internal view returns (address) {
        return AccessControlUpgradeable.getRoleMember(role, index);
    }

  /*  *//**
 * @dev Makes a safe call to another contract through the registry
 * @param _contractNameBytes32 Name of the contract to call
 * @param _callData The calldata to send
 * @return success Whether the call succeeded
 * @return returnData The data returned by the call
 *//*
    function _safeContractCall(
        bytes32 _contractNameBytes32,
        bytes memory _callData
    ) internal returns (bool success, bytes memory returnData) {
        require(address(registry) != address(0), "TeachToken: registry not set");

        try registry.isContractActive(_contractNameBytes32) returns (bool isActive) {
            if (!isActive) {
                emit BurnNotificationFailed(0, "Contract not active");
                return (false, bytes(""));
            }

            try registry.getContractAddress(_contractNameBytes32) returns (address contractAddress) {
                if (contractAddress == address(0)) {
                    emit BurnNotificationFailed(0, "Zero contract address");
                    return (false, bytes(""));
                }

                // Make the actual call
                (success, returnData) = contractAddress.call(_callData);

                if (!success) {
                    emit BurnNotificationFailed(0, "Call reverted");
                }

                return (success, returnData);
            } catch {
                emit BurnNotificationFailed(0, "Failed to get contract address");
                return (false, bytes(""));
            }
        } catch {
            emit BurnNotificationFailed(0, "Failed to check contract active status");
            return (false, bytes(""));
        }
    }*/
    
}