// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./Registry/RegistryAwareUpgradeable.sol";
import {Constants} from "./Libraries/Constants.sol";

// Interfaces for DEX interactions
interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path)
    external view returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
}

interface IStakingRewards {
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function earned(address account) external view returns (uint256);
}

    error ZeroAddress();
/**
 * @title LiquidityManager
 * @dev Manages liquidity across multiple DEXes for the TEACH token
 */
contract LiquidityManager is
OwnableUpgradeable,
ReentrancyGuardUpgradeable,
RegistryAwareUpgradeable,
UUPSUpgradeable
{
    // DEX details
    struct DexInfo {
        string name;
        address router;
        address factory;
        address pair;
        address stakingRewards; // For LP token staking
        uint256 allocationPercentage; // Percentage allocation (100 = 1%)
        bool active;
        uint256 dexId;
        uint256 price;
        uint256 tokenReserve;
        uint256 stableReserve;
    }

    // Liquidity phase details
    struct LiquidityPhase {
        uint256 tokenAmount;
        uint256 stablecoinAmount;
        uint256 targetPrice; // Target price in USD (scaled by 1e6)
        uint256 deadline;
        bool executed;
    }
    
    // Primary token and stablecoin
    ERC20Upgradeable public token;
    ERC20Upgradeable public stablecoin;

    // Target price for token in USD (scaled by 1e6)
    uint256 public targetTokenPrice;

    // Price floor for swaps (scaled by 1e6)
    uint256 public priceFloor;

    // DEX configurations
    DexInfo[] public dexes;

    // Liquidity deployment phases
    LiquidityPhase[] public liquidityPhases;

    // Liquidity position status
    mapping(uint256 => uint256) public dexLpTokenBalance; // DEX ID => LP token balance
    mapping(uint256 => bool) public dexLpOwnershipRenounced; // DEX ID => ownership renounced

    // Mapping of supported DEX routers
    mapping(address => bool) public supportedRouters;

    // Price monitoring
    uint256 public lastPriceUpdateTime;
    uint256 public currentPrice; // Current token price in stablecoin

    // Rebalancing parameters
    uint256 public maxPriceDivergence; // Maximum allowed price divergence between DEXes (100 = 1%)
    uint256 public maxReserveImbalance; // Maximum allowed reserve imbalance (100 = 1%)
    uint256 public rebalanceCooldown; // Cooldown period between rebalancing operations
    uint256 public lastRebalanceTime;

    // Events
    event DexAdded(uint256 indexed dexId, string name, address router, uint256 allocationPercentage);
    event DexActivated(uint256 indexed dexId);
    event DexDeactivated(uint256 indexed dexId);
    event LiquidityPhaseAdded(uint256 indexed phaseId, uint256 tokenAmount, uint256 stablecoinAmount, uint256 targetPrice);
    event LiquidityPhaseExecuted(uint256 indexed phaseId, uint256 tokenAmount, uint256 stablecoinAmount);
    event LiquidityProvided(uint256 indexed dexId, uint256 tokenAmount, uint256 stablecoinAmount, uint256 lpTokens);
    event LiquidityRemoved(uint256 indexed dexId, uint256 tokenAmount, uint256 stablecoinAmount, uint256 lpTokens);
    event OwnershipRenounced(uint256 indexed dexId);
    event LpTokensStaked(uint256 indexed dexId, uint256 amount);
    event LpRewardsClaimed(uint256 indexed dexId, uint256 amount);
    event SwapExecuted(uint256 indexed dexId, uint256 amountIn, uint256 amountOut, bool isTokenToStable);
    event PriceUpdated(uint256 newPrice);
    event TargetPriceUpdated(uint256 newTargetPrice);
    event PriceFloorUpdated(uint256 newPriceFloor);
    event RebalancingPerformed(uint256 timestamp);
    event LiquidityHealthWarning(uint256 indexed dexId, string reason);

    /**
     * @dev Initializes the contract with initial parameters
     * @param _token Address of the TEACH token
     * @param _stablecoin Address of the stablecoin
     * @param _targetPrice Initial target price in USD (scaled by 1e6)
     */
    function initialize(
        address _token,
        address _stablecoin,
        uint256 _targetPrice
    ) initializer public {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();

        require(_token != address(0), "MultiDexLiquidityManager: zero token address");
        require(_stablecoin != address(0), "MultiDexLiquidityManager: zero stablecoin address");
        require(_targetPrice > 0, "MultiDexLiquidityManager: zero target price");

        token = ERC20Upgradeable(_token);
        stablecoin = ERC20Upgradeable(_stablecoin);
        targetTokenPrice = _targetPrice;
        priceFloor = _targetPrice / 2; // Default price floor at 50% of target price

        // Set default rebalancing parameters
        maxPriceDivergence = 500; // 5% divergence
        maxReserveImbalance = 1000; // 10% imbalance
        rebalanceCooldown = 1 days;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Required override for UUPS proxy pattern
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Constants.ADMIN_ROLE) {
        // Additional upgrade logic can be added here
    }

    /**
     * @dev Adds a new DEX to the supported list
     * @param _name Name of the DEX
     * @param _router Router contract address
     * @param _factory Factory contract address
     * @param _stakingRewards Staking rewards contract address (optional)
     * @param _allocationPercentage Percentage allocation (100 = 1%)
     * @return dexId ID of the added DEX
     */
    function addDex(
        string memory _name,
        address _router,
        address _factory,
        address _stakingRewards,
        uint256 _allocationPercentage
    ) external onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        require(_router != address(0), "MultiDexLiquidityManager: zero router address");
        require(_factory != address(0), "MultiDexLiquidityManager: zero factory address");
        require(bytes(_name).length > 0, "MultiDexLiquidityManager: empty name");

        // Validate allocation percentage
        uint256 totalAllocation = _allocationPercentage;
        for (uint256 i = 0; i < dexes.length; i++) {
            if (dexes[i].active) {
                totalAllocation += dexes[i].allocationPercentage;
            }
        }
        require(totalAllocation <= 10000, "MultiDexLiquidityManager: allocation exceeds 100%");

        // Check if pair exists or create it
        address pair = IUniswapV2Factory(_factory).getPair(address(token), address(stablecoin));
        if (pair == address(0)) {
            // Pair doesn't exist yet, we'll create it when we add liquidity
            pair = address(0);
        }

        // Add to supported routers
        supportedRouters[_router] = true;

        // Add the DEX
        uint256 dexId = dexes.length;
        dexes.push(DexInfo({
            name: _name,
            router: _router,
            factory: _factory,
            pair: pair,
            stakingRewards: _stakingRewards,
            allocationPercentage: _allocationPercentage,
            active: true
        }));

        emit DexAdded(dexId, _name, _router, _allocationPercentage);

        return dexId;
    }

    /**
     * @dev Activates a DEX
     * @param _dexId ID of the DEX to activate
     */
    function activateDex(uint256 _dexId) external onlyRole(Constants.ADMIN_ROLE) {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");
        require(!dexes[_dexId].active, "MultiDexLiquidityManager: DEX already active");

        dexes[_dexId].active = true;

        emit DexActivated(_dexId);
    }

    /**
     * @dev Deactivates a DEX
     * @param _dexId ID of the DEX to deactivate
     */
    function deactivateDex(uint256 _dexId) external onlyRole(Constants.ADMIN_ROLE) {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");
        require(dexes[_dexId].active, "MultiDexLiquidityManager: DEX not active");

        dexes[_dexId].active = false;

        emit DexDeactivated(_dexId);
    }

    /**
     * @dev Adds a new liquidity deployment phase
     * @param _tokenAmount Amount of tokens to deploy
     * @param _stablecoinAmount Amount of stablecoin to deploy
     * @param _targetPrice Target price for this phase
     * @param _deadline Deadline for execution
     * @return phaseId ID of the added phase
     */
    function addLiquidityPhase(
        uint256 _tokenAmount,
        uint256 _stablecoinAmount,
        uint256 _targetPrice,
        uint256 _deadline
    ) external onlyRole(Constants.ADMIN_ROLE) returns (uint256) {
        require(_tokenAmount > 0, "MultiDexLiquidityManager: zero token amount");
        require(_stablecoinAmount > 0, "MultiDexLiquidityManager: zero stablecoin amount");
        require(_targetPrice > 0, "MultiDexLiquidityManager: zero target price");
        require(_deadline > block.timestamp, "MultiDexLiquidityManager: deadline in the past");

        uint256 phaseId = liquidityPhases.length;
        liquidityPhases.push(LiquidityPhase({
            tokenAmount: _tokenAmount,
            stablecoinAmount: _stablecoinAmount,
            targetPrice: _targetPrice,
            deadline: _deadline,
            executed: false
        }));

        emit LiquidityPhaseAdded(phaseId, _tokenAmount, _stablecoinAmount, _targetPrice);

        return phaseId;
    }

    /**
     * @dev Creates liquidity at the target price
     * @param _tokenAmount Amount of tokens to add
     * @param _stablecoinAmount Amount of stablecoin to add
     */
    function createLiquidityAtTargetPrice(
        uint256 _tokenAmount,
        uint256 _stablecoinAmount
    ) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(_tokenAmount > 0, "MultiDexLiquidityManager: zero token amount");
        require(_stablecoinAmount > 0, "MultiDexLiquidityManager: zero stablecoin amount");

        // Ensure the contract has enough tokens
        require(token.balanceOf(address(this)) >= _tokenAmount, "MultiDexLiquidityManager: insufficient token balance");
        require(stablecoin.balanceOf(address(this)) >= _stablecoinAmount, "MultiDexLiquidityManager: insufficient stablecoin balance");

        // Distribute liquidity across DEXes according to allocation percentages
        for (uint256 i = 0; i < dexes.length; i++) {
            if (dexes[i].active) {
                // Calculate allocation for this DEX
                uint256 dexTokenAmount = (_tokenAmount * dexes[i].allocationPercentage) / 10000;
                uint256 dexStablecoinAmount = (_stablecoinAmount * dexes[i].allocationPercentage) / 10000;

                if (dexTokenAmount > 0 && dexStablecoinAmount > 0) {
                    _addLiquidityToDex(i, dexTokenAmount, dexStablecoinAmount);
                }
            }
        }
    }

    /**
     * @dev Executes the next pending liquidity phase
     */
    function executeNextLiquidityPhase() external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        // Find the next unexecuted phase
        uint256 phaseId = _findNextPendingPhase();
        require(phaseId < liquidityPhases.length, "MultiDexLiquidityManager: no pending phases");

        LiquidityPhase storage phase = liquidityPhases[phaseId];
        require(!phase.executed, "MultiDexLiquidityManager: phase already executed");
        require(block.timestamp <= phase.deadline, "MultiDexLiquidityManager: phase deadline passed");

        // Set the target price for this phase
        targetTokenPrice = phase.targetPrice;
        emit TargetPriceUpdated(targetTokenPrice);

        // Execute the liquidity deployment
        createLiquidityAtTargetPrice(phase.tokenAmount, phase.stablecoinAmount);

        // Mark as executed
        phase.executed = true;

        emit LiquidityPhaseExecuted(phaseId, phase.tokenAmount, phase.stablecoinAmount);
    }

    /**
     * @dev Deploys liquidity in phases
     * @param _phaseIds Array of phase IDs to execute
     */
    function deployLiquidityInPhases(uint256[] calldata _phaseIds) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        for (uint256 i = 0; i < _phaseIds.length; i++) {
            uint256 phaseId = _phaseIds[i];
            require(phaseId < liquidityPhases.length, "MultiDexLiquidityManager: invalid phase ID");

            LiquidityPhase storage phase = liquidityPhases[phaseId];
            require(!phase.executed, "MultiDexLiquidityManager: phase already executed");
            require(block.timestamp <= phase.deadline, "MultiDexLiquidityManager: phase deadline passed");

            // Set the target price for this phase
            targetTokenPrice = phase.targetPrice;
            emit TargetPriceUpdated(targetTokenPrice);

            // Execute the liquidity deployment
            createLiquidityAtTargetPrice(phase.tokenAmount, phase.stablecoinAmount);

            // Mark as executed
            phase.executed = true;

            emit LiquidityPhaseExecuted(phaseId, phase.tokenAmount, phase.stablecoinAmount);
        }
    }

    /**
     * @dev Creates and renounces ownership of liquidity
     * @param _tokenAmount Amount of tokens to add
     * @param _stablecoinAmount Amount of stablecoin to add
     * @param _deadAddress Address to renounce to (typically 0xdead)
     */
    function createAndRenounceLiquidity(
        uint256 _tokenAmount,
        uint256 _stablecoinAmount,
        address _deadAddress
    ) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(_tokenAmount > 0, "MultiDexLiquidityManager: zero token amount");
        require(_stablecoinAmount > 0, "MultiDexLiquidityManager: zero stablecoin amount");
        require(_deadAddress != address(0), "MultiDexLiquidityManager: zero dead address");

        // First create the liquidity
        createLiquidityAtTargetPrice(_tokenAmount, _stablecoinAmount);

        // Then renounce ownership for each DEX
        for (uint256 i = 0; i < dexes.length; i++) {
            if (dexes[i].active && !dexLpOwnershipRenounced[i]) {
                _renounceLpOwnership(i, _deadAddress);
            }
        }
    }

    /**
     * @dev Swaps tokens with a price floor protection
     * @param _dexId ID of the DEX to use
     * @param _amountIn Amount of input tokens
     * @param _minAmountOut Minimum amount of output tokens
     * @param _isTokenToStable Whether swapping from token to stablecoin
     * @return amountOut Amount of tokens received
     */
    function swapWithPriceFloor(
        uint256 _dexId,
        uint256 _amountIn,
        uint256 _minAmountOut,
        bool _isTokenToStable
    ) external nonReentrant returns (uint256 amountOut) {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");
        require(dexes[_dexId].active, "MultiDexLiquidityManager: DEX not active");
        require(_amountIn > 0, "MultiDexLiquidityManager: zero input amount");

        DexInfo storage dex = dexes[_dexId];

        // Check if pair exists
        require(dex.pair != address(0), "MultiDexLiquidityManager: pair not created");

        // Get current reserves
        (uint256 reserve0, uint256 reserve1, ) = _getReserves(dex.pair);

        // Determine token order in the pair
        address token0 = IUniswapV2Pair(dex.pair).token0();
        bool isToken0 = address(token) == token0;

        uint256 tokenReserve = isToken0 ? reserve0 : reserve1;
        uint256 stablecoinReserve = isToken0 ? reserve1 : reserve0;

        // Calculate current price
        uint256 currentPrice = (stablecoinReserve * 1e18) / tokenReserve;

        // If swapping token to stablecoin, check price floor
        if (_isTokenToStable) {
            require(currentPrice >= priceFloor, "MultiDexLiquidityManager: below price floor");

            // Transfer tokens from sender to contract
            require(token.transferFrom(msg.sender, address(this), _amountIn), "MultiDexLiquidityManager: transfer failed");

            // Approve router
            token.approve(dex.router, _amountIn);

            // Setup path
            address[] memory path = new address[](2);
            path[0] = address(token);
            path[1] = address(stablecoin);

            // Execute swap
            uint256[] memory amounts = IUniswapV2Router(dex.router).swapExactTokensForTokens(
                _amountIn,
                _minAmountOut,
                path,
                msg.sender,
                block.timestamp + 1800 // 30 minutes
            );

            amountOut = amounts[1];
        } else {
            // If swapping stablecoin to token, no price floor check needed

            // Transfer stablecoin from sender to contract
            require(stablecoin.transferFrom(msg.sender, address(this), _amountIn), "MultiDexLiquidityManager: transfer failed");

            // Approve router
            stablecoin.approve(dex.router, _amountIn);

            // Setup path
            address[] memory path = new address[](2);
            path[0] = address(stablecoin);
            path[1] = address(token);

            // Execute swap
            uint256[] memory amounts = IUniswapV2Router(dex.router).swapExactTokensForTokens(
                _amountIn,
                _minAmountOut,
                path,
                msg.sender,
                block.timestamp + 1800 // 30 minutes
            );

            amountOut = amounts[1];
        }

        emit SwapExecuted(_dexId, _amountIn, amountOut, _isTokenToStable);

        return amountOut;
    }

    /**
     * @dev Stakes LP tokens in a staking rewards contract
     * @param _dexId ID of the DEX
     * @param _amount Amount of LP tokens to stake
     */
    function stakeLPTokens(uint256 _dexId, uint256 _amount) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");
        require(dexes[_dexId].active, "MultiDexLiquidityManager: DEX not active");
        require(dexes[_dexId].stakingRewards != address(0), "MultiDexLiquidityManager: no staking rewards");
        require(_amount > 0, "MultiDexLiquidityManager: zero amount");

        DexInfo storage dex = dexes[_dexId];

        // Ensure the pair exists
        require(dex.pair != address(0), "MultiDexLiquidityManager: pair not created");

        // Check LP token balance
        IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);
        uint256 lpBalance = pair.balanceOf(address(this));
        require(lpBalance >= _amount, "MultiDexLiquidityManager: insufficient LP balance");

        // Approve staking contract
        pair.approve(dex.stakingRewards, _amount);

        // Stake LP tokens
        IStakingRewards(dex.stakingRewards).stake(_amount);

        // Update LP token balance tracking
        dexLpTokenBalance[_dexId] = lpBalance - _amount;

        emit LpTokensStaked(_dexId, _amount);
    }

    /**
     * @dev Claims rewards from staking LP tokens
     * @param _dexId ID of the DEX
     */
    function claimLPRewards(uint256 _dexId) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");
        require(dexes[_dexId].stakingRewards != address(0), "MultiDexLiquidityManager: no staking rewards");

        DexInfo storage dex = dexes[_dexId];

        // Check earned rewards
        uint256 earned = IStakingRewards(dex.stakingRewards).earned(address(this));
        require(earned > 0, "MultiDexLiquidityManager: no rewards to claim");

        // Claim rewards
        IStakingRewards(dex.stakingRewards).getReward();

        emit LpRewardsClaimed(_dexId, earned);
    }

    /**
     * @dev Renounces ownership of LP tokens
     * @param _dexId ID of the DEX
     * @param _deadAddress Address to send LP tokens to
     */
    function renounceLpOwnership(uint256 _dexId, address _deadAddress) external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");
        require(dexes[_dexId].active, "MultiDexLiquidityManager: DEX not active");
        require(!dexLpOwnershipRenounced[_dexId], "MultiDexLiquidityManager: ownership already renounced");
        require(_deadAddress != address(0), "MultiDexLiquidityManager: zero dead address");

        _renounceLpOwnership(_dexId, _deadAddress);
    }

    /**
     * @dev Internal function to renounce LP ownership
     * @param _dexId ID of the DEX
     * @param _deadAddress Address to send LP tokens to
     */
    function _renounceLpOwnership(uint256 _dexId, address _deadAddress) internal {
        DexInfo storage dex = dexes[_dexId];

        // Ensure the pair exists
        require(dex.pair != address(0), "MultiDexLiquidityManager: pair not created");

        // Get LP token balance
        IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);
        uint256 lpBalance = pair.balanceOf(address(this));

        if (lpBalance > 0) {
            // Send LP tokens to dead address
            pair.transfer(_deadAddress, lpBalance);

            // Mark as renounced
            dexLpOwnershipRenounced[_dexId] = true;

            emit OwnershipRenounced(_dexId);
        } else {
            revert("MultiDexLiquidityManager: no LP tokens to renounce");
        }
    }

    /**
     * @dev Updates the target token price
     * @param _newTargetPrice New target price in USD (scaled by 1e6)
     */
    function updateTargetPrice(uint256 _newTargetPrice) external onlyRole(Constants.ADMIN_ROLE) {
        require(_newTargetPrice > 0, "MultiDexLiquidityManager: zero target price");

        targetTokenPrice = _newTargetPrice;

        emit TargetPriceUpdated(_newTargetPrice);
    }

    /**
     * @dev Updates the price floor for swaps
     * @param _newPriceFloor New price floor in USD (scaled by 1e6)
     */
    function updatePriceFloor(uint256 _newPriceFloor) external onlyRole(Constants.ADMIN_ROLE) {
        require(_newPriceFloor > 0, "MultiDexLiquidityManager: zero price floor");
        require(_newPriceFloor <= targetTokenPrice, "MultiDexLiquidityManager: price floor above target");

        priceFloor = _newPriceFloor;

        emit PriceFloorUpdated(_newPriceFloor);
    }

    /**
     * @dev Updates rebalancing parameters
     * @param _maxPriceDivergence Maximum allowed price divergence between DEXes (100 = 1%)
     * @param _maxReserveImbalance Maximum allowed reserve imbalance (100 = 1%)
     * @param _rebalanceCooldown Cooldown period between rebalancing operations
     */
    function updateRebalancingParameters(
        uint256 _maxPriceDivergence,
        uint256 _maxReserveImbalance,
        uint256 _rebalanceCooldown
    ) external onlyRole(Constants.ADMIN_ROLE) {
        require(_maxPriceDivergence > 0, "MultiDexLiquidityManager: zero price divergence");
        require(_maxReserveImbalance > 0, "MultiDexLiquidityManager: zero reserve imbalance");

        maxPriceDivergence = _maxPriceDivergence;
        maxReserveImbalance = _maxReserveImbalance;
        rebalanceCooldown = _rebalanceCooldown;
    }

    /**
     * @dev Returns the count of DEXes
     * @return dexCount Number of configured DEXes
     */
    function getDexCount() external view returns (uint256 dexCount) {
        return dexes.length;
    }

    /**
     * @dev Returns the count of liquidity phases
     * @return phaseCount Number of configured liquidity phases
     */
    function getLiquidityPhaseCount() external view returns (uint256 phaseCount) {
        return liquidityPhases.length;
    }

    /**
     * @dev Returns LP token balance for a DEX
     * @param _dexId ID of the DEX
     * @return balance LP token balance
     */
    function getLpTokenBalance(uint256 _dexId) external view returns (uint256 balance) {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");

        DexInfo storage dex = dexes[_dexId];

        if (dex.pair != address(0)) {
            return IUniswapV2Pair(dex.pair).balanceOf(address(this));
        }

        return 0;
    }

    /**
     * @dev Returns token reserves for a DEX
     * @param _dexId ID of the DEX
     * @return tokenReserve Token reserve
     * @return stableReserve Stablecoin reserve
     * @return currentPrice Current token price
     * @return lpSupply Total LP token supply
     */
    function getDexReserves(uint256 _dexId) external view returns (
        uint256 tokenReserve,
        uint256 stableReserve,
        uint256 currentPrice,
        uint256 lpSupply
    ) {
        require(_dexId < dexes.length, "MultiDexLiquidityManager: invalid DEX ID");

        tokenReserve = 0;
        stableReserve = 0;
        currentPrice = 0;
        lpSupply = 0;

        DexInfo storage dex = dexes[_dexId];

        if (dex.pair != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);
            (uint256 reserve0, uint256 reserve1, ) = _getReserves(dex.pair);

            // Determine token order in the pair
            address token0 = pair.token0();
            bool isToken0 = address(token) == token0;

            tokenReserve = isToken0 ? reserve0 : reserve1;
            stableReserve = isToken0 ? reserve1 : reserve0;

            // Calculate current price
            if (tokenReserve > 0) {
                currentPrice = (stableReserve * 1e18) / tokenReserve;
            }

            lpSupply = pair.totalSupply();
        }
        else{
            revert ZeroAddress();
        }
    }

    /**
     * @dev Checks liquidity health across all DEXes
     * @return isHealthy Whether the liquidity is healthy
     * @return warnings Array of warning messages
     * @return dexIds Array of DEX IDs with warnings
     */
    function checkLiquidityHealth() external view returns (
        bool isHealthy,
        string[] memory warnings,
        uint256[] memory dexIds
    ) {
        // Count active DEXes with pairs
        uint256 activeDexCount = 0;
        for (uint256 i = 0; i < dexes.length; i++) {
            if (dexes[i].active && dexes[i].pair != address(0)) {
                activeDexCount++;
            }
        }

        // If no active DEXes, return false
        if (activeDexCount == 0) {
            warnings = new string[](1);
            warnings[0] = "No active DEXes with pairs";
            return (false, warnings, new uint256[](0));
        }

        // Initialize arrays for warnings
        warnings = new string[](activeDexCount * 3); // Max 3 warnings per DEX
        dexIds = new uint256[](activeDexCount * 3);

        uint256 warningCount = 0;
        isHealthy = true;

        // Check each active DEX
        for (uint256 i = 0; i < dexes.length; i++) {
            if (dexes[i].active && dexes[i].pair != address(0)) {
                DexInfo storage dex = dexes[i];
                IUniswapV2Pair pair = IUniswapV2Pair(dex.pair);

                // Get reserves
                (uint256 reserve0, uint256 reserve1, ) = _getReserves(dex.pair);

                // Determine token order
                address token0 = pair.token0();
                bool isToken0 = address(token) == token0;

                uint256 tokenReserve = isToken0 ? reserve0 : reserve1;
                uint256 stableReserve = isToken0 ? reserve1 : reserve0;

                // Check reserve sizes
                if (tokenReserve == 0 || stableReserve == 0) {
                    warnings[warningCount] = "Zero reserves detected";
                    dexIds[warningCount] = i;
                    warningCount++;
                    isHealthy = false;
                    continue;
                }

                // Calculate current price
                uint256 currentPrice = (stableReserve * 1e18) / tokenReserve;

                // Check price deviation from target
                uint256 priceDeviation;
                if (currentPrice > targetTokenPrice) {
                    priceDeviation = ((currentPrice - targetTokenPrice) * 10000) / targetTokenPrice;
                } else {
                    priceDeviation = ((targetTokenPrice - currentPrice) * 10000) / targetTokenPrice;
                }

                if (priceDeviation > maxPriceDivergence) {
                    warnings[warningCount] = "Price deviation exceeds threshold";
                    dexIds[warningCount] = i;
                    warningCount++;
                    isHealthy = false;
                }

                // Check token reserve imbalance (if tokenReserve value is significantly different from stableReserve value)
                uint256 tokenValue = (tokenReserve * currentPrice) / 1e18;
                uint256 imbalance;

                if (tokenValue > stableReserve) {
                    imbalance = ((tokenValue - stableReserve) * 10000) / tokenValue;
                } else {
                    imbalance = ((stableReserve - tokenValue) * 10000) / stableReserve;
                }

                if (imbalance > maxReserveImbalance) {
                    warnings[warningCount] = "Reserve imbalance exceeds threshold";
                    dexIds[warningCount] = i;
                    warningCount++;
                    isHealthy = false;
                }
            }
        }

        // Trim arrays to actual warning count
        assembly {
            mstore(warnings, warningCount)
            mstore(dexIds, warningCount)
        }
    }

    /**
     * @dev Returns the next pending liquidity phase
     * @return phaseId ID of the next pending phase, or the total count if none
     */
    function _findNextPendingPhase() internal view returns (uint256) {
        for (uint256 i = 0; i < liquidityPhases.length; i++) {
            if (!liquidityPhases[i].executed && block.timestamp <= liquidityPhases[i].deadline) {
                return i;
            }
        }

        return liquidityPhases.length;
    }

    /**
     * @dev Performs rebalancing across DEXes if needed
     * This will adjust liquidity to keep prices aligned
     */
    function performRebalancing() external onlyRole(Constants.ADMIN_ROLE) nonReentrant {
        require(block.timestamp >= lastRebalanceTime + rebalanceCooldown, "MultiDexLiquidityManager: rebalancing on cooldown");

        uint256 activeDexCount = 0;
        for (uint256 i = 0; i < dexes.length; i++) {
        if (dexes[i].active && dexes[i].pair != address(0)) {
        activeDexCount++;
        }
        }

        if (activeDexCount < 2) {
        revert("MultiDexLiquidityManager: at least 2 active DEXes required");
        }

        DexInfo[] memory dexInfos = new DexInfo[](activeDexCount);
        uint256 infoIndex = 0;

        // Collect price and reserve info
        for (uint256 i = 0; i < dexes.length; i++) {
    if (dexes[i].active && dexes[i].pair != address(0)) {
    (uint256 reserve0, uint256 reserve1, ) = _getReserves(dexes[i].pair);

    // Determine token order
    address token0 = IUniswapV2Pair(dexes[i].pair).token0();
    bool isToken0 = address(token) == token0;

    uint256 tokenReserve = isToken0 ? reserve0 : reserve1;
    uint256 stableReserve = isToken0 ? reserve1 : reserve0;

    // Calculate price
    uint256 price = tokenReserve > 0 ? (stableReserve * 1e18) / tokenReserve : 0;

    dexInfos[infoIndex] = DexInfo({
    dexId: i,
    price: price,
    tokenReserve: tokenReserve,
    stableReserve: stableReserve
    });

    infoIndex++;
    }
    }

        // Find DEX with price furthest below target and DEX with price furthest above target
        uint256 lowestPriceDexIndex = 0;
        uint256 highestPriceDexIndex = 0;
        uint256 lowestDelta = type(uint256).max;
        uint256 highestDelta = type(uint256).max;

        for (uint256 i = 0; i < dexInfos.length; i++) {
        if (dexInfos[i].price < targetTokenPrice) {
        uint256 delta = targetTokenPrice - dexInfos[i].price;
        if (delta < lowestDelta) {
        lowestDelta = delta;
        lowestPriceDexIndex = i;
        }
        } else {
        uint256 delta = dexInfos[i].price - targetTokenPrice;
        if (delta < highestDelta) {
        highestDelta = delta;
        highestPriceDexIndex = i;
        }
        }
        }

        // Calculate divergence
        uint256 divergence;
        if (dexInfos[highestPriceDexIndex].price > dexInfos[lowestPriceDexIndex].price) {
        divergence = ((dexInfos[highestPriceDexIndex].price - dexInfos[lowestPriceDexIndex].price) * 10000) /
        dexInfos[lowestPriceDexIndex].price;
        } else {
        divergence = 0;
        }

        // Only rebalance if divergence exceeds threshold
        if (divergence > maxPriceDivergence) {
        // Rebalancing strategy: move liquidity from high price DEX to low price DEX
        // Implementation depends on whether we want to actually move liquidity or just perform swaps

        // For now, we'll log the rebalancing need
        lastRebalanceTime = block.timestamp;
        emit RebalancingPerformed(block.timestamp);
        }
    }

    /**
     * @dev Internal function to add liquidity to a DEX
     * @param _dexId ID of the DEX
     * @param _tokenAmount Amount of tokens to add
     * @param _stablecoinAmount Amount of stablecoin to add
     */
    function _addLiquidityToDex(
        uint256 _dexId,
        uint256 _tokenAmount,
        uint256 _stablecoinAmount
    ) internal {
        DexInfo storage dex = dexes[_dexId];

        // Approve router to spend tokens
        token.approve(dex.router, _tokenAmount);
        stablecoin.approve(dex.router, _stablecoinAmount);

        // Add liquidity
        (uint256 tokenAmountAdded, uint256 stablecoinAmountAdded, uint256 liquidity) =
                                IUniswapV2Router(dex.router).addLiquidity(
                address(token),
                address(stablecoin),
                _tokenAmount,
                _stablecoinAmount,
                0, // Accept any amount of tokens
                0, // Accept any amount of stablecoin
                address(this),
                block.timestamp + 1800 // 30 minutes deadline
            );

        // Update pair address if it's not set yet
        if (dex.pair == address(0)) {
            dex.pair = IUniswapV2Factory(dex.factory).getPair(address(token), address(stablecoin));
        }

        // Update LP token balance
        dexLpTokenBalance[_dexId] += liquidity;

        emit LiquidityProvided(_dexId, tokenAmountAdded, stablecoinAmountAdded, liquidity);
    }

    /**
     * @dev Internal function to get pair reserves
     * @param _pair Address of the pair contract
     * @return reserve0 Reserve of token0
     * @return reserve1 Reserve of token1
     * @return blockTimestampLast Timestamp of last update
     */
    function _getReserves(address _pair) internal view returns (uint256 reserve0, uint256 reserve1, uint32 blockTimestampLast) {
        (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) =
                                IUniswapV2Pair(_pair).getReserves();
        return (uint256(_reserve0), uint256(_reserve1), _blockTimestampLast);
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyRole(Constants.ADMIN_ROLE) {
        _setRegistry(_registry, keccak256("LIQUIDITY_MANAGER"));
    }

    /**
     * @dev Emergency function to recover tokens sent to this contract by mistake
     * @param _token Address of the token to recover
     */
    function recoverTokens(address _token) external onlyRole(Constants.ADMIN_ROLE) {
        require(_token != address(token) && _token != address(stablecoin), "MultiDexLiquidityManager: cannot recover core tokens");

        // Also prevent recovering any LP tokens
        for (uint256 i = 0; i < dexes.length; i++) {
            if (dexes[i].pair != address(0)) {
                require(_token != dexes[i].pair, "MultiDexLiquidityManager: cannot recover LP tokens");
            }
        }

        uint256 balance = ERC20Upgradeable(_token).balanceOf(address(this));
        require(balance > 0, "MultiDexLiquidityManager: no tokens to recover");

        ERC20Upgradeable(_token).transfer(msg.sender, balance);
    }
}