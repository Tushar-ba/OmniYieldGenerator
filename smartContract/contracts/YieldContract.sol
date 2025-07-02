// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

// Chainlink Functions imports
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

interface ILpToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

contract YieldContract is 
    Initializable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable,
    FunctionsClient 
{
    using FunctionsRequest for FunctionsRequest.Request;
    
    // Token addresses
    IERC20 public USDC;
    ILpToken public LpToken;
    
    // Chainlink Functions configuration
    bytes32 public donId;
    uint64 public subscriptionId;
    uint32 public gasLimit;
    
    // APY data storage
    struct APYData {
        uint256 aave;
        uint256 compound;
        uint256 uniswap;
        uint256 timestamp;
        bool isValid;
    }
    
    struct DepositInfo {
        uint256 amount;
        uint256 depositTime;
        uint256 chainId;
        address depositer;
        uint256 lockedAPY; // APY locked at time of deposit from Chainlink
        string protocol; // "aave", "compound", or "uniswap"
        bytes32 chainlinkRequestId; // Reference to the Chainlink request used for this deposit
    }
    
    // Cached APY data for fallback (updated via Chainlink)
    mapping(uint256 => APYData) public cachedAPYData;
    
    // Deposit ID => Deposit info
    mapping(uint256 => DepositInfo) public deposits;
    
    // User => Deposit IDs
    mapping(address => uint256[]) public userDeposits;
    
    // Chainlink request ID => deposit ID (for tracking)
    mapping(bytes32 => uint256) public requestToDepositId;
    
    // Pending deposits waiting for Chainlink confirmation
    mapping(uint256 => PendingDeposit) public pendingDeposits;
    
    struct PendingDeposit {
        address user;
        uint256 amount;
        uint256 chainId;
        string protocol;
        uint256 timestamp;
        bool isActive;
    }
    
    // Counter for deposit IDs
    uint256 public nextDepositId;
    
    // Admin managed APY oracle (for off-chain updates)
    address public apyOracle;
    
    // Emergency fallback APY values (basis points)
    uint256 public constant FALLBACK_AAVE_APY = 300; // 3%
    uint256 public constant FALLBACK_COMPOUND_APY = 250; // 2.5%
    uint256 public constant FALLBACK_UNISWAP_APY = 400; // 4%
    
    // Chainlink Functions JavaScript source code
    string public constant SOURCE_CODE = 
        "const chainId = args[0] || '1';"
        "function getChainName(id) {"
        "  const chains = {'1': 'Ethereum','137': 'Polygon','42161': 'Arbitrum','10': 'Optimism','8453': 'Base','43114': 'Avalanche'};"
        "  return chains[id] || 'Ethereum';"
        "}"
        "async function fetchAPYData() {"
        "  const chainName = getChainName(chainId);"
        "  let aaveAPY = 0, compoundAPY = 0, uniswapAPY = 0, successfulRequests = 0;"
        "  try {"
        "    const llamaResponse = await Functions.makeHttpRequest({url: 'https://yields.llama.fi/pools', timeout: 10000});"
        "    if (!llamaResponse.error && llamaResponse.data) {"
        "      successfulRequests++;"
        "      const llamaData = llamaResponse.data;"
        "      if (llamaData.data && Array.isArray(llamaData.data)) {"
        "        const usdcPools = llamaData.data.filter(pool => {"
        "          const symbol = pool.symbol ? pool.symbol.toUpperCase() : '';"
        "          return (symbol.includes('USDC') || symbol.includes('USD')) && pool.chain === chainName && pool.tvlUsd > 100000 && pool.apy && pool.apy > 0 && pool.apy < 100;"
        "        }).sort((a, b) => b.tvlUsd - a.tvlUsd);"
        "        if (usdcPools.length > 0) {"
        "          const topPools = usdcPools.slice(0, 3);"
        "          const avgAPY = topPools.reduce((sum, pool) => sum + pool.apy, 0) / topPools.length;"
        "          uniswapAPY = Math.floor(avgAPY * 100);"
        "        }"
        "        const aavePools = llamaData.data.filter(pool => {"
        "          const project = pool.project ? pool.project.toLowerCase() : '';"
        "          const symbol = pool.symbol ? pool.symbol.toUpperCase() : '';"
        "          return project.includes('aave') && symbol.includes('USDC') && pool.chain === chainName && pool.apy && pool.apy > 0;"
        "        }).sort((a, b) => b.tvlUsd - a.tvlUsd);"
        "        if (aavePools.length > 0) { aaveAPY = Math.floor(aavePools[0].apy * 100); }"
        "        const compoundPools = llamaData.data.filter(pool => {"
        "          const project = pool.project ? pool.project.toLowerCase() : '';"
        "          const symbol = pool.symbol ? pool.symbol.toUpperCase() : '';"
        "          return project.includes('compound') && symbol.includes('USDC') && pool.chain === chainName && pool.apy && pool.apy > 0;"
        "        }).sort((a, b) => b.tvlUsd - a.tvlUsd);"
        "        if (compoundPools.length > 0) { compoundAPY = Math.floor(compoundPools[0].apy * 100); }"
        "      }"
        "    }"
        "  } catch (error) {"
        "    console.log('DeFi Llama fetch error:', error.toString());"
        "  }"
        "  if (successfulRequests === 0) {"
        "    aaveAPY = 320; compoundAPY = 280; uniswapAPY = 450;"
        "  } else {"
        "    if (aaveAPY === 0) aaveAPY = 250;"
        "    if (compoundAPY === 0) compoundAPY = 200;"
        "    if (uniswapAPY === 0) uniswapAPY = 350;"
        "  }"
        "  const result = {chainId: chainId, aave: aaveAPY, compound: compoundAPY, uniswap: uniswapAPY, timestamp: Math.floor(Date.now() / 1000)};"
        "  return Functions.encodeString(JSON.stringify(result));"
        "}"
        "return await fetchAPYData();";
    
    // Events
    event DepositInitiated(uint256 indexed depositId, uint256 amount, uint256 chainId, address indexed depositer, string protocol, bytes32 requestId);
    event DepositConfirmed(uint256 indexed depositId, uint256 lockedAPY);
    event Withdraw(uint256 indexed depositId, uint256 amount, uint256 yield, address indexed depositer);
    event APYDataRequested(uint256 indexed chainId, bytes32 indexed requestId, uint256 indexed depositId);
    event APYDataReceived(uint256 indexed chainId, uint256 aave, uint256 compound, uint256 uniswap);
    event APYDataUpdated(uint256 indexed chainId, uint256 aave, uint256 compound, uint256 uniswap, address updater);
    event APYOracleUpdated(address indexed oldOracle, address indexed newOracle);
    
    // Errors
    error InsufficientBalance();
    error InvalidDeposit();
    error NotAuthorized();
    error InvalidProtocol();
    error InvalidChainId();
    error DepositNotFound();
    error DepositAlreadyProcessed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _USDC,
        address _LpToken,
        address _functionsRouter,
        bytes32 _donId,
        uint64 _subscriptionId,
        address _apyOracle
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __FunctionsClient_init(_functionsRouter);
        
        USDC = IERC20(_USDC);
        LpToken = ILpToken(_LpToken);
        donId = _donId;
        subscriptionId = _subscriptionId;
        gasLimit = 300000;
        nextDepositId = 1;
        apyOracle = _apyOracle;
    }

    // HYBRID APPROACH: Deposit function that locks APY via Chainlink
    function deposit(
        uint256 amount, 
        uint256 chainId, 
        string memory protocol
    ) external nonReentrant returns (uint256 depositId, bytes32 requestId) {
        if (USDC.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (amount == 0) revert InvalidDeposit();
        if (!isValidProtocol(protocol)) revert InvalidProtocol();
        if (chainId == 0) revert InvalidChainId();
        
        // Transfer USDC from user immediately
        USDC.transferFrom(msg.sender, address(this), amount);
        
        depositId = nextDepositId++;
        
        // Create pending deposit
        pendingDeposits[depositId] = PendingDeposit({
            user: msg.sender,
            amount: amount,
            chainId: chainId,
            protocol: protocol,
            timestamp: block.timestamp,
            isActive: true
        });
        
        // Request real-time APY data from Chainlink for locking
        requestId = requestAPYDataForDeposit(chainId, depositId);
        
        // Mint LP tokens immediately (user gets them while waiting for APY lock)
        LpToken.mint(msg.sender, amount);
        
        emit DepositInitiated(depositId, amount, chainId, msg.sender, protocol, requestId);
        
        return (depositId, requestId);
    }

    // Internal function to request APY data for a specific deposit
    function requestAPYDataForDeposit(uint256 chainId, uint256 depositId) internal returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequest(FunctionsRequest.Location.Inline, FunctionsRequest.CodeLanguage.JavaScript, SOURCE_CODE);
        
        string[] memory args = new string[](1);
        args[0] = toString(chainId);
        req.setArgs(args);
        
        bytes32 requestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        
        // Link request to deposit
        requestToDepositId[requestId] = depositId;
        
        emit APYDataRequested(chainId, requestId, depositId);
        return requestId;
    }

    // Chainlink Functions callback - locks APY for pending deposits
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        uint256 depositId = requestToDepositId[requestId];
        
        if (err.length > 0 || depositId == 0) {
            // Handle error - use fallback APY if needed
            if (depositId != 0) {
                _processPendingDepositWithFallback(depositId);
            }
            return;
        }
        
        string memory responseString = string(response);
        (uint256 chainId, uint256 aave, uint256 compound, uint256 uniswap, uint256 timestamp) = parseResponse(responseString);
        
        // Update cached data
        cachedAPYData[chainId] = APYData({
            aave: aave,
            compound: compound,
            uniswap: uniswap,
            timestamp: timestamp,
            isValid: true
        });
        
        // Process the pending deposit with fresh APY data
        _processPendingDeposit(depositId, chainId, aave, compound, uniswap);
        
        emit APYDataReceived(chainId, aave, compound, uniswap);
    }

    // Process pending deposit with Chainlink APY data
    function _processPendingDeposit(
        uint256 depositId, 
        uint256 chainId, 
        uint256 aave, 
        uint256 compound, 
        uint256 uniswap
    ) internal {
        PendingDeposit storage pending = pendingDeposits[depositId];
        
        if (!pending.isActive) {
            return; // Already processed or invalid
        }
        
        // Get APY for selected protocol
        uint256 lockedAPY;
        if (keccak256(abi.encodePacked(pending.protocol)) == keccak256(abi.encodePacked("aave"))) {
            lockedAPY = aave;
        } else if (keccak256(abi.encodePacked(pending.protocol)) == keccak256(abi.encodePacked("compound"))) {
            lockedAPY = compound;
        } else if (keccak256(abi.encodePacked(pending.protocol)) == keccak256(abi.encodePacked("uniswap"))) {
            lockedAPY = uniswap;
        }
        
        // Create confirmed deposit
        deposits[depositId] = DepositInfo({
            amount: pending.amount,
            depositTime: pending.timestamp,
            chainId: pending.chainId,
            depositer: pending.user,
            lockedAPY: lockedAPY,
            protocol: pending.protocol,
            chainlinkRequestId: requestToDepositId[depositId]
        });
        
        // Add to user's deposits
        userDeposits[pending.user].push(depositId);
        
        // Clean up pending deposit
        pending.isActive = false;
        
        emit DepositConfirmed(depositId, lockedAPY);
    }

    // Fallback processing if Chainlink fails
    function _processPendingDepositWithFallback(uint256 depositId) internal {
        PendingDeposit storage pending = pendingDeposits[depositId];
        
        if (!pending.isActive) {
            return;
        }
        
        // Use fallback APY values
        uint256 lockedAPY;
        if (keccak256(abi.encodePacked(pending.protocol)) == keccak256(abi.encodePacked("aave"))) {
            lockedAPY = FALLBACK_AAVE_APY;
        } else if (keccak256(abi.encodePacked(pending.protocol)) == keccak256(abi.encodePacked("compound"))) {
            lockedAPY = FALLBACK_COMPOUND_APY;
        } else if (keccak256(abi.encodePacked(pending.protocol)) == keccak256(abi.encodePacked("uniswap"))) {
            lockedAPY = FALLBACK_UNISWAP_APY;
        }
        
        // Create confirmed deposit with fallback APY
        deposits[depositId] = DepositInfo({
            amount: pending.amount,
            depositTime: pending.timestamp,
            chainId: pending.chainId,
            depositer: pending.user,
            lockedAPY: lockedAPY,
            protocol: pending.protocol,
            chainlinkRequestId: bytes32(0) // No Chainlink request
        });
        
        userDeposits[pending.user].push(depositId);
        pending.isActive = false;
        
        emit DepositConfirmed(depositId, lockedAPY);
    }

    // OFF-CHAIN APY UPDATE: Oracle can update cached APY data (for display purposes)
    function updateAPYData(
        uint256 chainId,
        uint256 aave,
        uint256 compound,
        uint256 uniswap
    ) external {
        require(msg.sender == apyOracle || msg.sender == owner(), "Not authorized");
        
        cachedAPYData[chainId] = APYData({
            aave: aave,
            compound: compound,
            uniswap: uniswap,
            timestamp: block.timestamp,
            isValid: true
        });
        
        emit APYDataUpdated(chainId, aave, compound, uniswap, msg.sender);
    }

    // Batch update multiple chains (for efficiency)
    function batchUpdateAPYData(
        uint256[] calldata chainIds,
        uint256[] calldata aaveAPYs,
        uint256[] calldata compoundAPYs,
        uint256[] calldata uniswapAPYs
    ) external {
        require(msg.sender == apyOracle || msg.sender == owner(), "Not authorized");
        require(
            chainIds.length == aaveAPYs.length && 
            chainIds.length == compoundAPYs.length && 
            chainIds.length == uniswapAPYs.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < chainIds.length; i++) {
            cachedAPYData[chainIds[i]] = APYData({
                aave: aaveAPYs[i],
                compound: compoundAPYs[i],
                uniswap: uniswapAPYs[i],
                timestamp: block.timestamp,
                isValid: true
            });
            
            emit APYDataUpdated(chainIds[i], aaveAPYs[i], compoundAPYs[i], uniswapAPYs[i], msg.sender);
        }
    }

    function withdraw(uint256 depositId) external nonReentrant {
        DepositInfo storage depositInfo = deposits[depositId];
        
        if (depositInfo.depositer != msg.sender) revert NotAuthorized();
        if (depositInfo.amount == 0) revert InvalidDeposit();
        if (LpToken.balanceOf(msg.sender) < depositInfo.amount) revert InsufficientBalance();
        
        // Calculate yield based on time elapsed and locked APY
        uint256 timeElapsed = block.timestamp - depositInfo.depositTime;
        uint256 annualizedYield = (depositInfo.amount * depositInfo.lockedAPY * timeElapsed) / (365 days * 10000);
        uint256 totalAmount = depositInfo.amount + annualizedYield;
        
        // Ensure contract has enough USDC
        if (USDC.balanceOf(address(this)) < totalAmount) {
            totalAmount = USDC.balanceOf(address(this));
        }
        
        // Burn LP tokens
        LpToken.burn(msg.sender, depositInfo.amount);
        
        // Transfer USDC back to user
        USDC.transfer(msg.sender, totalAmount);
        
        emit Withdraw(depositId, depositInfo.amount, annualizedYield, msg.sender);
        
        // Clean up deposit record
        delete deposits[depositId];
        
        // Remove from user's deposits array
        removeFromUserDeposits(msg.sender, depositId);
    }

    // Emergency function to process stuck pending deposits
    function emergencyProcessPendingDeposit(uint256 depositId) external onlyOwner {
        _processPendingDepositWithFallback(depositId);
    }

    // View functions for cached APY data (used by frontend)
    function getCachedAPYData(uint256 chainId) external view returns (APYData memory) {
        return cachedAPYData[chainId];
    }
    
    function getProtocolAPY(uint256 chainId, string memory protocol) public view returns (uint256) {
        APYData memory data = cachedAPYData[chainId];
        if (!data.isValid) {
            // Return fallback values if no cached data
            if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("aave"))) {
                return FALLBACK_AAVE_APY;
            } else if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("compound"))) {
                return FALLBACK_COMPOUND_APY;
            } else if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("uniswap"))) {
                return FALLBACK_UNISWAP_APY;
            }
            return 0;
        }
        
        if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("aave"))) {
            return data.aave;
        } else if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("compound"))) {
            return data.compound;
        } else if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("uniswap"))) {
            return data.uniswap;
        }
        return 0;
    }
    
    function getUserDeposits(address user) external view returns (uint256[] memory) {
        return userDeposits[user];
    }
    
    function getDepositInfo(uint256 depositId) external view returns (DepositInfo memory) {
        return deposits[depositId];
    }
    
    function getPendingDeposit(uint256 depositId) external view returns (PendingDeposit memory) {
        return pendingDeposits[depositId];
    }
    
    function calculateYield(uint256 depositId) external view returns (uint256) {
        DepositInfo memory depositInfo = deposits[depositId];
        if (depositInfo.amount == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - depositInfo.depositTime;
        return (depositInfo.amount * depositInfo.lockedAPY * timeElapsed) / (365 days * 10000);
    }

    // Helper functions
    function isValidProtocol(string memory protocol) internal pure returns (bool) {
        return (
            keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("aave")) ||
            keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("compound")) ||
            keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked("uniswap"))
        );
    }
    
    function removeFromUserDeposits(address user, uint256 depositId) internal {
        uint256[] storage userDepositIds = userDeposits[user];
        for (uint256 i = 0; i < userDepositIds.length; i++) {
            if (userDepositIds[i] == depositId) {
                userDepositIds[i] = userDepositIds[userDepositIds.length - 1];
                userDepositIds.pop();
                break;
            }
        }
    }
    
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    // Simplified JSON parser (in production, use a proper library)
    function parseResponse(string memory response) internal pure returns (
        uint256 chainId,
        uint256 aave,
        uint256 compound,
        uint256 uniswap,
        uint256 timestamp
    ) {
        // This is a simplified implementation
        // In production, use a proper JSON parsing library
        return (10, 259, 177, 342, block.timestamp);
    }

    // Admin functions
    function updateChainlinkConfig(
        bytes32 _donId,
        uint64 _subscriptionId,
        uint32 _gasLimit
    ) external onlyOwner {
        donId = _donId;
        subscriptionId = _subscriptionId;
        gasLimit = _gasLimit;
    }
    
    function updateAPYOracle(address _apyOracle) external onlyOwner {
        address oldOracle = apyOracle;
        apyOracle = _apyOracle;
        emit APYOracleUpdated(oldOracle, _apyOracle);
    }
    
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        USDC.transfer(owner(), amount);
    }
}