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
      gasPrice: 'auto'
    },
    // Bittensor Testnet
    bittensorTestnet: {
      url: process.env.BITTENSOR_TESTNET_RPC_URL || "	https://test.chain.opentensor.ai",
      chainId: 945,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gasPrice: 'auto'
    }
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY || "",
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      base: process.env.BASESCAN_API_KEY || "",
      baseSepolia: process.env.BASESCAN_API_KEY || "",
      arbitrumOne: process.env.ARBISCAN_API_KEY || "",
      polygon: process.env.POLYGONSCAN_API_KEY || ""
    }
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
