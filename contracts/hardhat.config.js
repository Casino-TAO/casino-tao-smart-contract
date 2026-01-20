require("@nomicfoundation/hardhat-toolbox");
require('dotenv').config({ path: '../.env' });

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1  // Minimum runs for smallest contract size
      },
      viaIR: true  // Enable IR-based code generation
    }
  },
  networks: {
    hardhat: {
      chainId: 1337
    },
    // Bittensor EVM (Subtensor)
    bittensor: {
      url: process.env.BITTENSOR_RPC_URL || "https://lite.chain.opentensor.ai",
      chainId: 964,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      // gasPrice: 'auto'
    },
    // Bittensor Testnet
    bittensorTestnet: {
      url: process.env.BITTENSOR_TESTNET_RPC_URL || "	https://test.chain.opentensor.ai",
      chainId: 945,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gasPrice: 'auto'
    },
    taostats: {
      url: "https://evm.taostats.io/api/eth-rpc",
    }
  },
  etherscan: {
    apiKey: {
      taostats: "casinotao",
    },
    customChains: [
      {
        network: "taostats",
        chainId: 964,
        urls: {
          apiURL: "https://evm.taostats.io/api/api",
          browserURL: "https://evm.taostats.io"
        }
      }
    ]
  },
  mocha: {
    timeout: 300000
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};
