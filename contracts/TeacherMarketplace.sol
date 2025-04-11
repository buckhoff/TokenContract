// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./RegistryAware.sol";

interface IPlatformStabilityFund {
    function getVerifiedPrice() external view returns (uint256);
    function processPlatformFees(uint256 _feeAmount) external;
}

/**
 * @title TeacherMarketplace
 * @dev Contract for teachers to create resources and for users to purchase them with TEACH tokens
 */
contract TeacherMarketplace is Ownable, ReentrancyGuard, Pausable, AccessControl, RegistryAware {
    // Registry contract names
    bytes32 public constant TEACH_TOKEN_NAME = keccak256("TEACH_TOKEN");
    bytes32 public constant STABILITY_FUND_NAME = keccak256("PLATFORM_STABILITY_FUND");
    bytes32 public constant GOVERNANCE_NAME = keccak256("TEACHER_GOVERNANCE");

    // Role constants
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // The TeachToken contract
    IERC20 public teachToken;
    
    // Struct to store resource information
    struct Resource {
        address creator;
        string metadataURI;
        uint256 price;
        bool isActive;
        uint256 sales;
        uint256 rating;
        uint256 ratingCount;
    }
    
    // Resource ID counter
    uint256 private _resourceIdCounter;
    
    // Mapping from resource ID to Resource struct
    mapping(uint256 => Resource) public resources;
    
    // Mapping from user to their purchased resources
    mapping(address => mapping(uint256 => bool)) public userPurchases;
    
    // Platform fee percentage (e.g., 5% = 500)
    uint256 public platformFeePercent;
    
    // Platform fee recipient address
    address public feeRecipient;

    IPlatformStabilityFund public stabilityFund;
    
    // Events
    event ResourceCreated(uint256 indexed resourceId, address indexed creator, string metadataURI, uint256 price);
    event ResourcePurchased(uint256 indexed resourceId, address indexed buyer, address indexed creator, uint256 price);
    event ResourceRated(uint256 indexed resourceId, address indexed rater, uint256 rating);
    event ResourceUpdated(uint256 indexed resourceId, string metadataURI, uint256 price, bool isActive);
    event PlatformFeeUpdated(uint256 newFeePercent);
    event FeeRecipientUpdated(address newFeeRecipient);
    // Events for registry integration
    event RegistrySet(address indexed registry);
    event ContractReferenceUpdated(bytes32 indexed contractName, address indexed oldAddress, address indexed newAddress);

    // Dispute resolution mapping for marketplace transactions
    mapping(uint256 => DisputeInfo) public resourceDisputes;
    uint256 public disputeResolutionPeriod = 7 days;

    // Struct for dispute information
    struct DisputeInfo {
        address buyer;
        address seller;
        uint256 amount;
        string reason;
        uint256 createdAt;
        bool resolved;
        bool refunded;
    }

    // Events for dispute resolution
    event DisputeCreated(uint256 indexed resourceId, address indexed buyer, address indexed seller, string reason);
    event DisputeResolved(uint256 indexed resourceId, bool refunded);

    // Subscription model variables
    mapping(address => uint256) public subscriptionEndTime;
    uint256 public monthlySubscriptionFee;
    uint256 public yearlySubscriptionDiscount; // Percentage discount for yearly subscriptions (e.g., 2000 = 20%)

    // Bulk purchase discount tiers
    struct DiscountTier {
        uint256 minAmount;      // Minimum purchase amount for this tier
        uint256 discountPercent; // Discount percentage (100 = 1%)
    }

    DiscountTier[] public discountTiers;

    // Events for subscription and bulk purchases
    event SubscriptionPurchased(address indexed user, uint256 duration, uint256 endTime);
    event BulkPurchaseDiscountApplied(address indexed buyer, uint256 resourceCount, uint256 discountPercent);

    /**
     * @dev Calculates token price from the stability fund (if available)
     * @param _stableAmount Amount in stable coins
     * @return tokenAmount Amount in TEACH tokens
     */
    function calculateTokenPrice(uint256 _stableAmount) public view returns (uint256 tokenAmount) {
        if (address(registry) != address(0) && registry.isContractActive(STABILITY_FUND_NAME)) {
            try IPlatformStabilityFund(registry.getContractAddress(STABILITY_FUND_NAME)).getVerifiedPrice() returns (uint256 verifiedPrice) {
                if (verifiedPrice > 0) {
                    return (_stableAmount * 1e18) / verifiedPrice;
                }
            } catch {
                // Fall back to a default calculation if stability fund call fails
            }
        }

        // Fallback calculation or default price if no stability fund
        return _stableAmount * 10; // Example fallback (10 TEACH per stable coin)
    }

    /**
     * @dev Sets the secondary market status
     * @param _resourceId Resource ID
     * @param _isResellable Whether the resource can be resold
     */
    function setResourceResellable(uint256 _resourceId, bool _isResellable) external {
        Resource storage resource = resources[_resourceId];
        require(resource.creator == msg.sender || hasRole(ADMIN_ROLE, msg.sender), "TeacherMarketplace: not authorized");
        require(resource.creator != address(0), "TeacherMarketplace: resource does not exist");

        // Update resellable status in new struct field or mapping
        // Implementation depends on how you want to store this
    }

    /**
     * @dev Creates a new educational resource
     * @param _metadataURI IPFS URI containing resource metadata
     * @param _price Price in TEACH tokens
     * @return resourceId The ID of the newly created resource
     */
    function createResource(string memory _metadataURI, uint256 _price) external nonReentrant whenSystemNotPaused whenNotPaused returns (uint256)
    {
        require(bytes(_metadataURI).length > 0, "TeacherMarketplace: empty metadata URI");
        require(_price > 0, "TeacherMarketplace: zero price");

        uint256 resourceId = _resourceIdCounter;
        _resourceIdCounter++;

        resources[resourceId] = Resource({
            creator: msg.sender,
            metadataURI: _metadataURI,
            price: _price,
            isActive: true,
            sales: 0,
            rating: 0,
            ratingCount: 0
        });

        emit ResourceCreated(resourceId, msg.sender, _metadataURI, _price);

        return resourceId;
    }

    /**
     * @dev Constructor sets the token address, fee percentage, and fee recipient
     * @param _teachToken Address of the TEACH token contract
     * @param _feePercent Platform fee percentage (e.g., 5% = 500)
     * @param _feeRecipient Address to receive platform fees
     */
    constructor(address _teachToken, uint256 _feePercent, address _feeRecipient) Ownable(msg.sender) {
        require(_teachToken != address(0), "TeacherMarketplace: zero token address");
        require(_feePercent <= 3000, "TeacherMarketplace: fee too high");
        require(_feeRecipient != address(0), "TeacherMarketplace: zero fee recipient");
        
        teachToken = IERC20(_teachToken);
        platformFeePercent = _feePercent;
        feeRecipient = _feeRecipient;
        _resourceIdCounter = 1;
        _setupRole(ADMIN_ROLE, msg.sender);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(EMERGENCY_ROLE, msg.sender);

        // Set default subscription fee
        monthlySubscriptionFee = 100 * 10**18; // 100 TEACH tokens per month
        yearlySubscriptionDiscount = 2000; // 20% discount for yearly subscription

        // Set up default discount tiers
        discountTiers.push(DiscountTier({minAmount: 5, discountPercent: 500}));   // 5+ resources: 5% discount
        discountTiers.push(DiscountTier({minAmount: 10, discountPercent: 1000})); // 10+ resources: 10% discount
        discountTiers.push(DiscountTier({minAmount: 25, discountPercent: 1500})); // 25+ resources: 15% discount
    }

    /**
     * @dev Sets the registry contract address
     * @param _registry Address of the registry contract
     */
    function setRegistry(address _registry) external onlyOwner {
        _setRegistry(_registry, keccak256("TEACHER_MARKETPLACE"));
        emit RegistrySet(_registry);
    }

    /**
     * @dev Update contract references from registry
     * This ensures contracts always have the latest addresses
     */
    function updateContractReferences() external onlyRole(ADMIN_ROLE) {
        require(address(registry) != address(0), "TeacherMarketplace: registry not set");

        // Update TeachToken reference
        if (registry.isContractActive(TEACH_TOKEN_NAME)) {
            address newTeachToken = registry.getContractAddress(TEACH_TOKEN_NAME);
            address oldTeachToken = address(teachToken);

            if (newTeachToken != oldTeachToken) {
                teachToken = IERC20(newTeachToken);
                emit ContractReferenceUpdated(TEACH_TOKEN_NAME, oldTeachToken, newTeachToken);
            }
        }

        // Update StabilityFund reference for price oracle
        if (registry.isContractActive(STABILITY_FUND_NAME)) {
            address stabilityFund = registry.getContractAddress(STABILITY_FUND_NAME);
            // No need to store this reference as we'll fetch it when needed
            emit ContractReferenceUpdated(STABILITY_FUND_NAME, address(0), stabilityFund);
        }
    }
    
    /**
     * @dev Creates a new educational resource
     * @param _metadataURI IPFS URI containing resource metadata
     * @param _price Price in TEACH tokens
     * @return resourceId The ID of the newly created resource
     */
    function createResource(string memory _metadataURI, uint256 _price) external nonReentrant whenNotPaused returns (uint256) {
        require(bytes(_metadataURI).length > 0, "TeacherMarketplace: empty metadata URI");
        require(_price > 0, "TeacherMarketplace: zero price");
        
        uint256 resourceId = _resourceIdCounter;
        _resourceIdCounter++;
        
        resources[resourceId] = Resource({
            creator: msg.sender,
            metadataURI: _metadataURI,
            price: _price,
            isActive: true,
            sales: 0,
            rating: 0,
            ratingCount: 0
        });
        
        emit ResourceCreated(resourceId, msg.sender, _metadataURI, _price);
        
        return resourceId;
    }
    
    /**
     * @dev Updates an existing resource
     * @param _resourceId Resource ID to update
     * @param _metadataURI New IPFS URI containing resource metadata
     * @param _price New price in TEACH tokens
     * @param _isActive Whether the resource is active and available for purchase
     */
    function updateResource(uint256 _resourceId, string memory _metadataURI, uint256 _price, bool _isActive) external whenNotPaused nonReentrant {
        Resource storage resource = resources[_resourceId];
        
        require(resource.creator != address(0), "TeacherMarketplace: resource does not exist");
        require(resource.creator == msg.sender, "TeacherMarketplace: not resource creator");
        require(bytes(_metadataURI).length > 0, "TeacherMarketplace: empty metadata URI");
        require(_price > 0, "TeacherMarketplace: zero price");
        
        resource.metadataURI = _metadataURI;
        resource.price = _price;
        resource.isActive = _isActive;
        
        emit ResourceUpdated(_resourceId, _metadataURI, _price, _isActive);
    }
    
    /**
     * @dev Purchases a resource using TEACH tokens
     * @param _resourceId Resource ID to purchase
     */
    function purchaseResource(uint256 _resourceId) external whenSystemNotPaused whenNotPaused nonReentrant {
        Resource storage resource = resources[_resourceId];
        
        require(resource.creator != address(0), "TeacherMarketplace: resource does not exist");
        require(resource.isActive, "TeacherMarketplace: resource not active");
        require(!userPurchases[msg.sender][_resourceId], "TeacherMarketplace: already purchased");
        require(resource.creator != msg.sender, "TeacherMarketplace: cannot purchase own resource");

        // Check if user has an active subscription
        if (subscriptionEndTime[msg.sender] >= block.timestamp) {
            // If subscribed, just mark as purchased without payment
            userPurchases[msg.sender][_resourceId] = true;
            resource.sales += 1;

            emit ResourcePurchased(_resourceId, msg.sender, resource.creator, 0);
            return;
        }
        
        uint256 price = resource.price;
        uint256 platformFee = (price * platformFeePercent) / 10000;
        uint256 creatorAmount = price - platformFee;
        
        // Transfer tokens
        require(teachToken.transferFrom(msg.sender, feeRecipient, platformFee), "TeacherMarketplace: fee transfer failed");
        require(teachToken.transferFrom(msg.sender, resource.creator, creatorAmount), "TeacherMarketplace: creator transfer failed");
        
        // Mark as purchased and update sales
        userPurchases[msg.sender][_resourceId] = true;
        resource.sales += 1;

        // If we have a connection to the stability fund, share a portion of fees with it
        if (address(registry) != address(0) && registry.isContractActive(STABILITY_FUND_NAME)) {
            try this.shareFeeWithStabilityFund(platformFee) {} catch {}
        }
        
        emit ResourcePurchased(_resourceId, msg.sender, resource.creator, price);
    }
    
    /**
     * @dev Rates a purchased resource
     * @param _resourceId Resource ID to rate
     * @param _rating Rating value (1-5)
     */
    function rateResource(uint256 _resourceId, uint256 _rating) external nonReentrant {
        require(userPurchases[msg.sender][_resourceId], "TeacherMarketplace: not purchased");
        require(_rating >= 1 && _rating <= 5, "TeacherMarketplace: invalid rating");
        
        Resource storage resource = resources[_resourceId];
        
        // Update rating
        uint256 totalRating = resource.rating * resource.ratingCount;
        resource.ratingCount += 1;
        resource.rating = (totalRating + _rating) / resource.ratingCount;
        
        emit ResourceRated(_resourceId, msg.sender, _rating);
    }
    
    /**
     * @dev Updates the platform fee percentage
     * @param _newFeePercent New fee percentage (e.g., 5% = 500)
     */
    function updatePlatformFee(uint256 _newFeePercent) external onlyOwner {
        require(_newFeePercent <= 3000, "TeacherMarketplace: fee too high");
        platformFeePercent = _newFeePercent;
        emit PlatformFeeUpdated(_newFeePercent);
    }
    
    /**
     * @dev Updates the fee recipient address
     * @param _newFeeRecipient New fee recipient address
     */
    function updateFeeRecipient(address _newFeeRecipient) external onlyOwner {
        require(_newFeeRecipient != address(0), "TeacherMarketplace: zero fee recipient");
        feeRecipient = _newFeeRecipient;
        emit FeeRecipientUpdated(_newFeeRecipient);
    }
    
    /**
     * @dev Returns resource details
     * @param _resourceId Resource ID to query
     * @return creator Resource creator address
     * @return metadataURI IPFS URI with resource metadata
     * @return price Resource price in TEACH tokens
     * @return isActive Whether resource is active
     * @return sales Number of sales
     * @return rating Average resource rating
     * @return ratingCount Number of ratings
     */
    function getResource(uint256 _resourceId) external view returns (
        address creator,
        string memory metadataURI,
        uint256 price,
        bool isActive,
        uint256 sales,
        uint256 rating,
        uint256 ratingCount
    ) {
        Resource storage resource = resources[_resourceId];
        return (
            resource.creator,
            resource.metadataURI,
            resource.price,
            resource.isActive,
            resource.sales,
            resource.rating,
            resource.ratingCount
        );
    }
    
    /**
     * @dev Checks if a user has purchased a specific resource
     * @param _user User address to check
     * @param _resourceId Resource ID to check
     * @return bool Whether the user has purchased the resource
     */
    function hasPurchased(address _user, uint256 _resourceId) external view returns (bool) {
        return userPurchases[_user][_resourceId];
    }

    // Add pause and unpause functions
    function pauseMarketplace() external {
        // Check if caller is StabilityFund or has EMERGENCY_ROLE
        if (address(registry) != address(0) && registry.isContractActive(STABILITY_FUND_NAME)) {
            address stabilityFund = registry.getContractAddress(STABILITY_FUND_NAME);
            require(
                msg.sender == stabilityFund || hasRole(EMERGENCY_ROLE, msg.sender),
                "TeacherMarketplace: not authorized"
            );
        } else {
            require(hasRole(EMERGENCY_ROLE, msg.sender), "TeacherMarketplace: not authorized");
        }
        _pause();
    }

    function unpauseMarketplace() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setStabilityFund(address _stabilityFund) external onlyOwner {
        require(_stabilityFund != address(0), "TeacherMarketplace: zero address");
        stabilityFund = IPlatformStabilityFund(_stabilityFund);
    }
    
    function calculateTokenPrice(uint256 _stableAmount) public view returns (uint256) {
        uint256 verifiedPrice = stabilityFund.getVerifiedPrice();
        return (_stableAmount * 1e18) / verifiedPrice;
    }

    /**
     * @dev Share a portion of the platform fee with the stability fund
     * This function can only be called by the contract itself
     * @param _fee Total platform fee collected
     */
    function shareFeeWithStabilityFund(uint256 _fee) external {
        require(msg.sender == address(this), "TeacherMarketplace: unauthorized");

        address stabilityFund = registry.getContractAddress(STABILITY_FUND_NAME);

        // Calculate portion to share (e.g., 20% of fee)
        uint256 portionToShare = (_fee * 2000) / 10000;

        if (portionToShare > 0) {
            // Approve the stability fund to take the tokens
            teachToken.approve(stabilityFund, portionToShare);

            // Call the processPlatformFees function in StabilityFund
            try IPlatformStabilityFund(stabilityFund).processPlatformFees(portionToShare) {
                // Success - no action needed
            } catch {
                // If call fails, we continue without reverting
            }
        }
    }

    /**
     * @dev Creates a dispute for a purchased resource
     * @param _resourceId Resource ID to dispute
     * @param _reason Reason for the dispute
     */
    function createDispute(uint256 _resourceId, string memory _reason) external nonReentrant {
        require(userPurchases[msg.sender][_resourceId], "TeacherMarketplace: not purchased");
        require(!resourceDisputes[_resourceId].resolved, "TeacherMarketplace: dispute already exists or resolved");

        Resource storage resource = resources[_resourceId];
        require(resource.creator != address(0), "TeacherMarketplace: resource does not exist");

        resourceDisputes[_resourceId] = DisputeInfo({
            buyer: msg.sender,
            seller: resource.creator,
            amount: resource.price,
            reason: _reason,
            createdAt: block.timestamp,
            resolved: false,
            refunded: false
        });

        emit DisputeCreated(_resourceId, msg.sender, resource.creator, _reason);
    }

    /**
     * @dev Resolves a dispute
     * @param _resourceId Resource ID of the dispute
     * @param _refund Whether to refund the buyer
     */
    function resolveDispute(uint256 _resourceId, bool _refund) external onlyRole(ADMIN_ROLE) nonReentrant {
        DisputeInfo storage dispute = resourceDisputes[_resourceId];
        require(!dispute.resolved, "TeacherMarketplace: already resolved");
        require(dispute.buyer != address(0), "TeacherMarketplace: dispute does not exist");
        require(block.timestamp <= dispute.createdAt + disputeResolutionPeriod, "TeacherMarketplace: resolution period ended");

        dispute.resolved = true;

        if (_refund) {
            // Issue refund to buyer
            dispute.refunded = true;

            // Use feeRecipient's balance (platform) to refund
            uint256 platformFee = (dispute.amount * platformFeePercent) / 10000;
            require(teachToken.transferFrom(feeRecipient, dispute.buyer, dispute.amount), "TeacherMarketplace: refund failed");
        }

        emit DisputeResolved(_resourceId, _refund);
    }

    /**
     * @dev Sets the dispute resolution period
     * @param _newPeriod New period in seconds
     */
    function setDisputeResolutionPeriod(uint256 _newPeriod) external onlyRole(ADMIN_ROLE) {
        require(_newPeriod > 0, "TeacherMarketplace: zero period");
        disputeResolutionPeriod = _newPeriod;
    }

    /**
     * @dev Purchases a subscription for marketplace access
     * @param _isYearly Whether the subscription is yearly or monthly
     */
    function purchaseSubscription(bool _isYearly) external nonReentrant whenSystemNotPaused whenNotPaused {
        uint256 duration;
        uint256 fee;

        if (_isYearly) {
            duration = 365 days;
            // Apply yearly discount
            fee = (monthlySubscriptionFee * 12 * (10000 - yearlySubscriptionDiscount)) / 10000;
        } else {
            duration = 30 days;
            fee = monthlySubscriptionFee;
        }

        // If user already has a subscription, extend it
        if (subscriptionEndTime[msg.sender] > block.timestamp) {
            subscriptionEndTime[msg.sender] += duration;
        } else {
            subscriptionEndTime[msg.sender] = block.timestamp + duration;
        }

        // Transfer tokens
        require(teachToken.transferFrom(msg.sender, feeRecipient, fee), "TeacherMarketplace: payment failed");

        // Share with stability fund
        if (address(registry) != address(0) && registry.isContractActive(STABILITY_FUND_NAME)) {
            try this.shareFeeWithStabilityFund(fee) {} catch {}
        }

        emit SubscriptionPurchased(msg.sender, duration, subscriptionEndTime[msg.sender]);
    }

    /**
     * @dev Sets subscription fees
     * @param _monthlyFee Monthly subscription fee
     * @param _yearlyDiscount Yearly subscription discount percentage
     */
    function setSubscriptionFees(uint256 _monthlyFee, uint256 _yearlyDiscount) external onlyRole(ADMIN_ROLE) {
        require(_yearlyDiscount <= 5000, "TeacherMarketplace: discount too high");
        monthlySubscriptionFee = _monthlyFee;
        yearlySubscriptionDiscount = _yearlyDiscount;
    }

    /**
     * @dev Bulk purchase multiple resources with discount
     * @param _resourceIds Array of resource IDs to purchase
     */
    function bulkPurchaseResources(uint256[] memory _resourceIds) external nonReentrant whenSystemNotPaused whenNotPaused {
        require(_resourceIds.length > 0, "TeacherMarketplace: empty purchase");

        // Calculate total cost and validate resources
        uint256 totalCost = 0;

        for (uint256 i = 0; i < _resourceIds.length; i++) {
            uint256 resourceId = _resourceIds[i];
            Resource storage resource = resources[resourceId];

            require(resource.creator != address(0), "TeacherMarketplace: resource does not exist");
            require(resource.isActive, "TeacherMarketplace: resource not active");
            require(!userPurchases[msg.sender][resourceId], "TeacherMarketplace: already purchased");
            require(resource.creator != msg.sender, "TeacherMarketplace: cannot purchase own resource");

            totalCost += resource.price;
        }

        // Check if user has an active subscription
        if (subscriptionEndTime[msg.sender] >= block.timestamp) {
            // If subscribed, just mark all as purchased without payment
            for (uint256 i = 0; i < _resourceIds.length; i++) {
                uint256 resourceId = _resourceIds[i];
                userPurchases[msg.sender][resourceId] = true;
                resources[resourceId].sales += 1;

                emit ResourcePurchased(resourceId, msg.sender, resources[resourceId].creator, 0);
            }
            return;
        }

        // Apply bulk purchase discount
        uint256 discountPercent = 0;
        for (uint256 i = 0; i < discountTiers.length; i++) {
            if (_resourceIds.length >= discountTiers[i].minAmount) {
                discountPercent = discountTiers[i].discountPercent;
            }
        }

        if (discountPercent > 0) {
            totalCost = (totalCost * (10000 - discountPercent)) / 10000;
            emit BulkPurchaseDiscountApplied(msg.sender, _resourceIds.length, discountPercent);
        }

        // Platform fee on the total
        uint256 platformFee = (totalCost * platformFeePercent) / 10000;

        // Transfer platform fee
        require(teachToken.transferFrom(msg.sender, feeRecipient, platformFee), "TeacherMarketplace: fee transfer failed");

        // Process each resource
        for (uint256 i = 0; i < _resourceIds.length; i++) {
            uint256 resourceId = _resourceIds[i];
            Resource storage resource = resources[resourceId];

            // Calculate creator's share with the discount applied
            uint256 discountedPrice = (resource.price * (10000 - discountPercent)) / 10000;
            uint256 creatorFee = discountedPrice - ((discountedPrice * platformFeePercent) / 10000);

            // Transfer to creator
            require(teachToken.transferFrom(msg.sender, resource.creator, creatorFee), "TeacherMarketplace: creator transfer failed");

            // Mark as purchased
            userPurchases[msg.sender][resourceId] = true;
            resource.sales += 1;

            emit ResourcePurchased(resourceId, msg.sender, resource.creator, discountedPrice);
        }

        // Share platform fee with stability fund
        if (address(registry) != address(0) && registry.isContractActive(STABILITY_FUND_NAME)) {
            try this.shareFeeWithStabilityFund(platformFee) {} catch {}
        }
    }

    /**
     * @dev Updates discount tiers
     * @param _minAmounts Array of minimum amounts for each tier
     * @param _discountPercents Array of discount percentages for each tier
     */
    function updateDiscountTiers(
        uint256[] memory _minAmounts,
        uint256[] memory _discountPercents
    ) external onlyRole(ADMIN_ROLE) {
        require(_minAmounts.length == _discountPercents.length, "TeacherMarketplace: arrays length mismatch");
        require(_minAmounts.length > 0, "TeacherMarketplace: empty tiers");

        // Clear existing tiers
        delete discountTiers;

        // Add new tiers
        for (uint256 i = 0; i < _minAmounts.length; i++) {
            require(_minAmounts[i] > 0, "TeacherMarketplace: zero min amount");
            require(_discountPercents[i] <= 5000, "TeacherMarketplace: discount too high");

            discountTiers.push(DiscountTier({
                minAmount: _minAmounts[i],
                discountPercent: _discountPercents[i]
            }));
        }
    }

}