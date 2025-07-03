//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";


contract Contract is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public USDC;
    address public LpToken;

    struct Deposit {
        uint256 amount;
        uint256 yield;
        uint256 depositeTime;
        string protocol;
        uint256 chainId;
    }

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

    mapping(address => Deposit) public deposits;


    event Deposit(address indexed user, uint256 amount, string protocol, uint256 chainId);

    error InvalidAmount();
    error InvalidSender();
    error InvalidProtocol();
    error InvalidChainId();

    function initialize( address _USDC, address _LpToken) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        USDC = _USDC;
        LpToken = _LpToken;
    }

    function deposite(uint256 _amount, string memory _protocol, uint256 _chainId) public {
        if(_amount <= 0) revert InvalidAmount();
        if(msg.sender == address(0)) revert InvalidSender();
        if(bytes(_protocol).length == 0) revert InvalidProtocol();
        if(_chainId == 0) revert InvalidChainId();

        Deposit memory deposit = Deposit({
            amount: _amount,
            yield: 0,
            depositeTime: block.timestamp,
            protocol: _protocol,
            chainId: _chainId
        });

        IERC20(USDC).transferFrom(msg.sender, address(this), _amount);
        IERC20(LpToken).mint(msg.sender, _amount);
        emit Deposit(msg.sender, _amount, _protocol, _chainId);
    }

    function APYInfo(uint256 _chainId) public view returns (uint256 aave, uint256 compound, uint256 uniswap) {
        (uint256 aave, uint256 compound, uint256 uniswap) = APYOracle.getAPY(_chainId);
        return (aave, compound, uniswap);
    }

    function getAPY(uint256 _chainId) internal view returns (uint256 aave, uint256 compound, uint256 uniswap) {
        FunctionsRequest.Request memory req;
        //so 
        req.initializeRequest(FunctionsRequest.Location.Inline, FunctionsRequest.CodeLanguage.JavaScript, SOURCE_CODE);
        
        

    }


    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}