// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TeacherMarketplace
 * @dev Contract for teachers to create resources and for users to purchase them with TEACH tokens
 */
contract TeacherMarketplace is Ownable, ReentrancyGuard, Pausable {
    // The TeachToken contract
    IERC20 public teachToken;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
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
    
    // Events
    event ResourceCreated(uint256 indexed resourceId, address indexed creator, string metadataURI, uint256 price);
    event ResourcePurchased(uint256 indexed resourceId, address indexed buyer, address indexed creator, uint256 price);
    event ResourceRated(uint256 indexed resourceId, address indexed rater, uint256 rating);
    event ResourceUpdated(uint256 indexed resourceId, string metadataURI, uint256 price, bool isActive);
    event PlatformFeeUpdated(uint256 newFeePercent);
    event FeeRecipientUpdated(address newFeeRecipient);
    
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
    function purchaseResource(uint256 _resourceId) external whenNotPaused nonReentrant {
        Resource storage resource = resources[_resourceId];
        
        require(resource.creator != address(0), "TeacherMarketplace: resource does not exist");
        require(resource.isActive, "TeacherMarketplace: resource not active");
        require(!userPurchases[msg.sender][_resourceId], "TeacherMarketplace: already purchased");
        require(resource.creator != msg.sender, "TeacherMarketplace: cannot purchase own resource");
        
        uint256 price = resource.price;
        uint256 platformFee = (price * platformFeePercent) / 10000;
        uint256 creatorAmount = price - platformFee;
        
        // Transfer tokens
        require(teachToken.transferFrom(msg.sender, feeRecipient, platformFee), "TeacherMarketplace: fee transfer failed");
        require(teachToken.transferFrom(msg.sender, resource.creator, creatorAmount), "TeacherMarketplace: creator transfer failed");
        
        // Mark as purchased and update sales
        userPurchases[msg.sender][_resourceId] = true;
        resource.sales += 1;
        
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
    function pauseMarketplace() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpauseMarketplace() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}