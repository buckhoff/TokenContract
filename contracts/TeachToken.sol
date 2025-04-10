// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title TeachToken
 * @dev Implementation of the TEACH Token for the TeacherSupport Platform on Polygon
 */
contract TeachToken is ERC20, ERC20Burnable, Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // Maximum supply cap
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 10**18; // 5 billion tokens

    // Track if initial distribution has been performed
    bool private initialDistributionDone;
    
    // Events
    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);
    event BurnerAdded(address indexed account);
    event BurnerRemoved(address indexed account);
    event TokensBurned(address indexed burner, uint256 amount);
    event InitialDistributionComplete(uint256 timestamp);

    /**
     * @dev Constructor that initializes the token with name, symbol, and roles
     */
    constructor() ERC20("TeacherSupport Token", "TEACH") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        initialDistributionDone = false;

        // Initial minting for token distribution
        // _mint(msg.sender, 1_600_000_000 * 10**18); // 32% for Platform Ecosystem
        //_mint(msg.sender, 1_100_000_000 * 10**18); // 22% for Community Incentives
        //_mint(msg.sender, 700_000_000 * 10**18);   // 14% for Initial Liquidity
        //_mint(msg.sender, 500_000_000 * 10**18);   // 10% for Public Presale
        //_mint(msg.sender, 500_000_000 * 10**18);   // 10% for Team and Development
        //_mint(msg.sender, 400_000_000 * 10**18);   // 8% for Educational Partners
        //_mint(msg.sender, 200_000_000 * 10**18);   // 4% for Reserve
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
     * Requirements: Caller must have the PAUSER_ROLE
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers
     * Requirements: Caller must have the PAUSER_ROLE
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     * Requirements: Caller must have the MINTER_ROLE
     * Total supply must not exceed MAX_SUPPLY
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "TeachToken: Max supply exceeded");
        _mint(to, amount);
    }

    /**
     * @dev Burns tokens from a specified address
     * Can only be called by an account with BURNER_ROLE
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyRole(BURNER_ROLE) nonReentrant {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
        emit TokensBurned(from, amount);
    }
    
    /**
     * @dev Adds a new minter with rights to mint tokens
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function addMinter(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(MINTER_ROLE, account);
        emit MinterAdded(account);
    }

    /**
     * @dev Removes a minter
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function removeMinter(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(MINTER_ROLE, account);
        emit MinterRemoved(account);
    }

    /**
     * @dev Adds a new burner with rights to burn tokens
     * @param account Address to be granted the burner role
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function addBurner(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(BURNER_ROLE, account);
        emit BurnerAdded(account);
    }

    /**
     * @dev Removes a burner
     * @param account Address to have the burner role revoked
     * Requirements: Caller must have the DEFAULT_ADMIN_ROLE
     */
    function removeBurner(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(BURNER_ROLE, account);
        emit BurnerRemoved(account);
    }
    
    /**
     * @dev Hook that is called before any transfer of tokens.
     * Prevents transfers when the contract is paused.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused
    {
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
 * @dev Allows the admin to recover tokens accidentally sent to the contract
 * @param tokenAddress The address of the token to recover
 * @param amount The amount of tokens to recover
 */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(tokenAddress != address(this), "TeachToken: Cannot recover TEACH tokens");
        require(amount > 0, "TeachToken: Zero amount");

        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= amount, "TeachToken: Insufficient balance");

        bool success = token.transfer(msg.sender, amount);
        require(success, "TeachToken: Transfer failed");
    }
}