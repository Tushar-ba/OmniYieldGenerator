//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";


contract Contract is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    address public USDC;
    address public LpToken;
    uint256 public subscriptionId;
    uint256 public gasLimit;
    address public donId;
    uint256 public currentDepositId;

    

    struct APYDataAave {
        uint256 chainId;
        uint256 aave;
        uint256 timestamp;
    }

    struct APYDataUniswap {
        uint256 chainId;
        uint256 uniswap;
        uint256 timestamp;
    }

    struct APYDataCompound {
        uint256 chainId;
        uint256 compound;
        uint256 timestamp;
    }


    struct Deposit {
        uint256 amount;
        uint256 depositeTime;
        string project;
        string symbol;
        string chain;
        uint256 apy;
        uint256 depositId;
    }   

    mapping(uint256 => APYDataAave) public apyDataAave;
    mapping(uint256 => APYDataUniswap) public apyDataUniswap;
    mapping(uint256 => APYDataCompound) public apyDataCompound;

    string public constant SOURCE_CODE = 
    "const chain = args[0] || 'Ethereum';"
    "const project = args[1] || 'aave-v3';"
    "const symbol = args[2] || 'USDC';"
    "const url = `https://omniyieldgenerator.onrender.com/pools/${chain}/${project}/${symbol}`;"
    "console.log('Testing URL:', url);"
    "console.log('Parameters:', { chain, project, symbol });"
    "try {"
    "  const apiResponse = await Functions.makeHttpRequest({"
    "    url: url,"
    "    method: 'GET',"
    "    headers: {"
    "      'Content-Type': 'application/json',"
    "      'Accept': 'application/json'"
    "    }"
    "  });"
    "  console.log('Response status:', apiResponse.status);"
    "  console.log('Response data:', JSON.stringify(apiResponse.data, null, 2));"
    "  if (apiResponse.error) {"
    "    console.error('API Error:', apiResponse.error);"
    "    return Functions.encodeString('ERROR');"
    "  }"
    "  if (!apiResponse.data || !apiResponse.data.success) {"
    "    console.error('No successful data received');"
    "    return Functions.encodeString('NO_DATA');"
    "  }"
    "  const data = apiResponse.data.data;"
    "  if (!data || !Array.isArray(data) || data.length === 0) {"
    "    console.error('Invalid data structure');"
    "    return Functions.encodeString('INVALID_DATA');"
    "  }"
    "  const poolData = data[0];"
    "  const apy = poolData.apy;"
    "  if (apy === null || apy === undefined) {"
    "    console.error('APY is null or undefined');"
    "    return Functions.encodeString('NO_APY');"
    "  }"
    "  console.log('Extracted APY:', apy);"
    "  const apyString = apy.toFixed(5);"
    "  console.log('Returning APY string:', apyString);"
    "  return Functions.encodeString(apyString);"
    "} catch (error) {"
    "  console.error('Caught error:', error);"
    "  return Functions.encodeString('EXCEPTION');"
    "}";

    mapping(address => mapping(uint256 => Deposit)) public deposits;


    event Deposit(address indexed user, uint256 amount, string protocol, uint256 chainId);

    error InvalidAmount();
    error InvalidSender();
    error InvalidProtocol();
    error InvalidChainId();
    error InvalidDepositId();

    function initialize( address _USDC, address _LpToken) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        USDC = _USDC;
        LpToken = _LpToken;
    }

    function deposite(uint256 _amount, string memory _project, string memory _symbol, string memory _chain, uint256 _chainId) public {
        if(_amount <= 0) revert InvalidAmount();
        if(msg.sender == address(0)) revert InvalidSender();
        if(bytes(_project).length == 0) revert InvalidProtocol();
        if(_chainId == 0) revert InvalidChainId();

        uint256 depositId = currentDepositId++;

        uint256 apy = chooseProject(_project);
        if(apy == 0) revert InvalidAPY();

        Deposit memory deposit = Deposit({
            amount: _amount,
            depositeTime: block.timestamp,
            project: _project,
            apy: apy,
            symbol: _symbol,
            chain: _chain,
            depositId: depositId
        });

        IERC20(USDC).transferFrom(msg.sender, address(this), _amount);
        IERC20(LpToken).mint(msg.sender, _amount);
        emit Deposit(msg.sender, _amount, _project, _chainId, depositId);
    }

    function withdraw(uint256 _amount, uint256 _depositId) public {
        if(_depositId == 0) revert InvalidDepositId();
        if(deposits[msg.sender][_depositId].amount == 0) revert InvalidDepositId();
        if(deposits[msg.sender][_depositId].amount < _amount) revert InvalidAmount();
        if(_amount <= 0) revert InvalidAmount();
        if(msg.sender == address(0)) revert InvalidSender();

        IERC20(LpToken).transferFrom(msg.sender, address(this), _amount);
        uint256 yieldAmount = _amount * deposits[msg.sender][_depositId].apy / 10000;
        IERC20(USDC).approve(msg.sender, yieldAmount);
        IERC20(USDC).transfer(msg.sender, yieldAmount);
        emit Withdraw(msg.sender, _amount, yieldAmount);
    }

    function getAPY(string memory _chain, string memory _project, string memory _symbol) internal view returns (bytes32) {
        FunctionsRequest.Request memory req;
        //so 
        req.initializeRequest(FunctionsRequest.Location.Inline, FunctionsRequest.CodeLanguage.JavaScript, SOURCE_CODE);
        string[] memory args = new string[](3);
        args[0] = _chain;
        args[1] = _project;
        args[2] = _symbol;
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        updateAPY(requestId, _chain, _project);

        emit APYUpdated(requestId, _chain, _project);

        return requestId;
    }

    function updateAPY(bytes32 _requestIda, string memory _chainId, string memory _project) public {
        if(string.length(_chainId) == 0) revert InvalidChainId();
        if(bytes(_data).length == 0) revert InvalidData();
        if(_project == "aave-v3") {
            APYDataAave memory apyData = APYDataAave({
                chainId: _chainId,
                aave: _data,
                timestamp: block.timestamp
            });
        } else if(_project == "uniswap") {
            APYDataUniswap memory apyData = APYDataUniswap({
                chainId: _chainId,
                uniswap: _data,
                timestamp: block.timestamp
            });
        } else {
            APYDataCompound memory apyData = APYDataCompound({
                chainId: _chainId,
                compound: _data,
                timestamp: block.timestamp
            });
        }
    }

    function chooseProject(string memory _project) internal view returns (uint256) {
        if(_project == "aave-v3") {
            return apyDataAave.aave;
        } else if(_project == "uniswap") {
            return apyDataUniswap.uniswap;
        } else if(_project == "compound") {
            return apyDataCompound.compound;
        }
    }


    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}