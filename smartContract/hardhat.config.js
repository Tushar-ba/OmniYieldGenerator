require("@nomicfoundation/hardhat-toolbox");
require("hardhat-deploy");
const { EndpointId } = require('@layerzerolabs/lz-definitions');

const accounts = process.env.ADMIN_PRIVATE_KEY ? [process.env.ADMIN_PRIVATE_KEY] : [];

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.22",
  networks: {
    'optimism-sepolia-testnet': {
        eid: EndpointId.OPTSEP_V2_TESTNET,
        url: process.env.RPC_URL_OP_SEPOLIA || 'https://optimism-sepolia.gateway.tenderly.co',
        accounts,
    },
    'avalanche-fuji-testnet': {
        eid: EndpointId.AVALANCHE_V2_TESTNET,
        url: process.env.RPC_URL_FUJI || 'https://avalanche-fuji.drpc.org',
        accounts,
    },
    'arbitrum-sepolia-testnet': {
        eid: EndpointId.ARBSEP_V2_TESTNET,
        url: process.env.RPC_URL_ARB_SEPOLIA || 'https://arbitrum-sepolia.gateway.tenderly.co',
        accounts,
    },
  },
  namedAccounts: {
    deployer: {
      default: 0,
    },
  },
};
