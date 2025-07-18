// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

interface IImmutableTokenContract {
    function MAX_SUPPLY() external pure returns (uint256);
    function TOKEN_NAME() external pure returns (string memory);
    function TOKEN_SYMBOL() external pure returns (string memory);
    function calculateAllocation(uint256 allocationBPS) external pure returns (uint256);

    // Allocation constants
    function PUBLIC_PRESALE_ALLOCATION_BPS() external pure returns (uint256);
    function COMMUNITY_INCENTIVES_ALLOCATION_BPS() external pure returns (uint256);
    function PLATFORM_ECOSYSTEM_ALLOCATION_BPS() external pure returns (uint256);
    function INITIAL_LIQUIDITY_ALLOCATION_BPS() external pure returns (uint256);
    function TEAM_DEV_ALLOCATION_BPS() external pure returns (uint256);
    function EDUCATIONAL_PARTNERS_ALLOCATION_BPS() external pure returns (uint256);
    function RESERVE_ALLOCATION_BPS() external pure returns (uint256);
}

/**
 * @title TeachToken
 * @dev Implementation of the TEACH Token for the TeacherSupport Platform on Polygon
 */
contract TeachToken is
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    AccessControlEnumerableUpgradeable,
    RegistryAwareUpgradeable
{
    IImmutableTokenContract public immutableContract;
    
    bool internal paused;
    bool public inEmergencyRecovery;
    bool internal initialDistributionDone;
    mapping(address => bool) public emergencyRecoveryApprovals;
    uint256 public requiredRecoveryApprovals;

    address private _cachedTokenAddress;
    address private _cachedStabilityFundAddress;
    uint256 private _lastCacheUpdate;

    mapping(address => bool) public recoveryAllowedTokens;

    // Events
    event RegistrySet(address indexed registry);
    event InitialDistributionComplete(uint256 timestamp);
    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);
    event BurnerAdded(address indexed account);
    event BurnerRemoved(address indexed account);
    event BurnNotificationSent(uint256 amount);
    event BurnNotificationFailed(uint256 amount, string reason);
    event TokensBurned(address indexed burner, uint256 amount);
    event RecoveryTokenStatusChanged(address indexed token, bool allowed);
    event ERC20TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event EmergencyRecoveryInitiated(address indexed recoveryAdmin, uint256 timestamp);
    event EmergencyRecoveryCompleted(address indexed recoveryAdmin);
    event immutableContractSet(address indexed immutableContract);
    
    error ZeroTokenAddress();
    error ZeroAmount();
    error TokenNotActiveOrRegistered();
    error InitialDistributionAlreadyCompleted();
    error TotalAllocationMustEqualMaxSupply();
    error SystemStillPaused();
    error CannotAllowTeachToken();
    error CannotRecoverTeachTokens();
    error TokenRecoveryNotAllowed();
    error InsufficientBalance();
    error TransferFailed();
    error NotPaused();
    error NotInRecoveryMode();
    error AlreadyApproved();
    
    /**
     * @dev Constructor that initializes the token with name, symbol, and roles
     */
    //constructor() {
    //    _disableInitializers();
    //}

    /**
    * @dev Initializes the contract replacing the constructor
     */
    function initialize(address _immutableContract) initializer public {
        if(_immutableContract == address(0)) revert ZeroContractAddress();
        immutableContract = IImmutableTokenContract(_immutableContract);
        
        __ERC20_init( 
            immutableContract.TOKEN_NAME(),
            immutableContract.TOKEN_SYMBOL()
        );
        __ERC20Burnable_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        // Limit the number of admin role holders to 10 for DoS safety
        require(getRoleMemberCount(Constants.ADMIN_ROLE) < 10, "Too many admin role holders");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
        _grantRole(Constants.MINTER_ROLE, msg.sender);
        _grantRole(Constants.BURNER_ROLE, msg.sender);
        initialDistributionDone = false;
        requiredRecoveryApprovals = 3;

        emit immutableContractSet(_immutableContract);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }
    
    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        if (_registry == address(0)) revert ZeroContractAddress();
        _setRegistry(_registry, Constants.TOKEN_NAME);
        emit RegistrySet(_registry);
    }

    /**
     * @dev Returns the chain ID of the current blockchain.
     * @return chainId of the current blockchain
     */
    function getChainId() public view returns (uint256) {
        return block.chainid;
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
        if (initialDistributionDone) revert InitialDistributionAlreadyCompleted();
        address[7] memory addresses = [
                    platformEcosystemAddress,
                    communityIncentivesAddress,
                    initialLiquidityAddress,
                    publicPresaleAddress,
                    teamAndDevAddress,
                    educationalPartnersAddress,
                    reserveAddress
            ];

        for (uint256 i = 0; i < addresses.length; i++) {
            if(addresses[i] == address(0)) revert("Zero address not allowed");
        }

        for (uint256 i = 0; i < addresses.length - 1; i++) {
            for (uint256 j = i + 1; j < addresses.length; j++) {
                if(addresses[i] == addresses[j])  revert("Duplicate addresses not allowed");
            }
        }

        uint256 publicPresaleAmount = immutableContract.calculateAllocation(
            immutableContract.PUBLIC_PRESALE_ALLOCATION_BPS()
        );

        uint256 communityIncentivesAmount = immutableContract.calculateAllocation(
            immutableContract.COMMUNITY_INCENTIVES_ALLOCATION_BPS()
        );

        uint256 platformEcosystemAmount = immutableContract.calculateAllocation(
            immutableContract.PLATFORM_ECOSYSTEM_ALLOCATION_BPS()
        );

        uint256 initialLiquidityAmount = immutableContract.calculateAllocation(
            immutableContract.INITIAL_LIQUIDITY_ALLOCATION_BPS()
        );

        uint256 teamAndDevAmount = immutableContract.calculateAllocation(
            immutableContract.TEAM_DEV_ALLOCATION_BPS()
        );

        uint256 educationalPartnersAmount = immutableContract.calculateAllocation(
            immutableContract.EDUCATIONAL_PARTNERS_ALLOCATION_BPS()
        );

        uint256 reserveAmount = immutableContract.calculateAllocation(
            immutableContract.RESERVE_ALLOCATION_BPS()
        );

        // Validate that the sum of all allocations equals MAX_SUPPLY
        uint256 totalAllocation = platformEcosystemAmount + communityIncentivesAmount +
                    initialLiquidityAmount + publicPresaleAmount +
                    teamAndDevAmount + educationalPartnersAmount +
                    reserveAmount;

        if (totalAllocation != immutableContract.MAX_SUPPLY()) revert TotalAllocationMustEqualMaxSupply();
        
        // Public Presale (25%)
        _mint(publicPresaleAddress, publicPresaleAmount);

        // Community Incentives (24%)
        _mint(communityIncentivesAddress, communityIncentivesAmount);
        
        // Platform Ecosystem (20%)
        _mint(platformEcosystemAddress, platformEcosystemAmount);
        
        // Initial Liquidity (12%)
        _mint(initialLiquidityAddress, initialLiquidityAmount);

        // Team and Development (8%)
        _mint(teamAndDevAddress, teamAndDevAmount);

        // Educational Partners (7%)
        _mint(educationalPartnersAddress, educationalPartnersAmount);

        // Reserve (4%)
        _mint(reserveAddress, reserveAmount);

        initialDistributionDone = true;
        emit InitialDistributionComplete(block.timestamp);
    }
    
    /**
     * @dev Check if the initial distribution has been completed
     * @return Boolean indicating if initial distribution is done
     */
    function isInitialDistributionComplete() public view returns (bool) {
        return initialDistributionDone;
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

        if(address(registry) == address(0)) revert ZeroContractAddress();
        bytes32 stabilityFundName = Constants.STABILITY_FUND_NAME;
            
        try registry.isContractActive(stabilityFundName) returns (bool isActive) {
            if (isActive) {
                
                // Create the calldata
                bytes memory callData = abi.encodeWithSignature(
                    "processBurnedTokens(uint256)",
                    amount
                );
                // Call the stability fund's processBurnedTokens function
                (bool success, ) = _safeContractCall( stabilityFundName, callData);
                
                // We don't revert if this call fails to maintain the primary burn functionality
                if (success) {
                    emit BurnNotificationSent(amount);
                } else {
                    revert("Call to stability fund failed");
                    emit BurnNotificationFailed(amount, "Call to stability fund failed");
                }
            }
            else{
                revert("SF not active");
            }
        } catch{
            emit BurnNotificationFailed(amount, "Failed to check stability fund status");
        }
    }
    
    /**
     * @dev Adds a new minter with rights to mint tokens
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    //function addMinter(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
    //    grantRole(Constants.MINTER_ROLE, account);
    //    emit MinterAdded(account);
    //}

    /**
     * @dev Removes a minter
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    //function removeMinter(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
    //    revokeRole(Constants.MINTER_ROLE, account);
    //    emit MinterRemoved(account);
    //}

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
    function _update(address from, address to, uint256 amount) internal override whenContractNotPaused
    {
        super._update(from, to, amount);
    }

    /**
 * @dev Pauses all token transfers
     * Requirements: Caller must have the ADMIN_ROLE
     */
    function pause() public onlyRole(Constants.ADMIN_ROLE){
        paused=true;
    }

    /**
     * @dev Unpauses all token transfers
     * Requirements: Caller must have the ADMIN_ROLE
     */
    function unpause() public onlyRole(Constants.ADMIN_ROLE) {
        // Check if system is still paused before unpausing locally
        if (address(registry) != address(0)) {
            try registry.isSystemPaused() returns (bool systemPaused) {
                if (systemPaused) revert SystemStillPaused();
            } catch {
                // If registry call fails, proceed with unpause
            }
        }

        paused = false;
    }

    function _isContractPaused() internal override view returns (bool) {
        return paused;
    }
    
    /**
     * @dev Set whether a token is allowed to be recovered
     * @param _token Address of the token
     * @param _allowed Whether recovery is allowed
     */
    function setRecoveryAllowedToken(address _token, bool _allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(0)) revert ZeroTokenAddress();
        if (_token == address(this)) revert CannotAllowTeachToken();

        recoveryAllowedTokens[_token] = _allowed;

        emit RecoveryTokenStatusChanged(_token, _allowed);
    }
    
    /**
    * @dev Allows the admin to recover tokens accidentally sent to the contract
    * @param tokenAddress The address of the token to recover
    * @param amount The amount of tokens to recover
    */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (tokenAddress == address(this)) revert CannotRecoverTeachTokens();
        if (amount == 0) revert ZeroAmount();
        if (!recoveryAllowedTokens[tokenAddress]) revert TokenRecoveryNotAllowed();

        ERC20Upgradeable token = ERC20Upgradeable(tokenAddress);
        if (token.balanceOf(address(this)) < amount) revert InsufficientBalance();

        bool success = token.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        emit ERC20TokensRecovered(tokenAddress, msg.sender, amount);
    }

    // Add emergency recovery functions
    function initiateEmergencyRecovery() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!paused) revert NotPaused();
        inEmergencyRecovery = true;
        emit EmergencyRecoveryInitiated(msg.sender, block.timestamp);
    }

    function approveRecovery() external onlyRole(Constants.ADMIN_ROLE) {
        if (!inEmergencyRecovery) revert NotInRecoveryMode();
        if (emergencyRecoveryApprovals[msg.sender]) revert AlreadyApproved();

        emergencyRecoveryApprovals[msg.sender] = true;

        if (_countRecoveryApprovals() >= requiredRecoveryApprovals) {
            inEmergencyRecovery = false;
            this.unpause();
            emit EmergencyRecoveryCompleted(msg.sender);
        }
    }

    function _countRecoveryApprovals() internal view returns (uint256) {
        // WARNING: This function loops through all ADMIN_ROLE holders. For DoS safety, never have more than 10 admins.
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
        if (address(registry) != address(0)) {
            try registry.getContractAddress(Constants.STABILITY_FUND_NAME) returns (address stabilityFundAddress) {
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
        
        // Final fallback: Use hardcoded address (if appropriate) or revert
        revert("Stability Fund address unavailable through all fallback mechanisms");
    }

    /**
     * @dev Retrieves the address of the Token contract, with fallback mechanisms
     * @return The address of the token contract
     */
    function getTokenAddressWithFallback() internal returns (address) {
        // First attempt: Try registry lookup
        if (address(registry) != address(0)) {
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

        return address(this);
    }
}