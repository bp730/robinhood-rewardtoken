import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
    // Mainnet Configuration
    robinhood: {
      type: "http",
      url: configVariable("RH_MAINNET_RPC_URL"), // https://robinhood-mainnet.g.alchemy.com/v2
      chainId: 4663, // Official Mainnet Chain ID
      chainType: "op",
      accounts: [configVariable("PRIVATE_KEY")],
    },
    // Testnet Configuration
    "robinhood-testnet": {
      type: "http",
      url: configVariable("RH_TESTNET_RPC_URL"), //  "https://robinhood-testnet.g.alchemy.com/v2",
      chainId: 46630, // Official Testnet Chain ID
      chainType: "op",
      accounts: [configVariable("TEST_PRIVATE_KEY")],
    }
  },
  verify: {
    blockscout: {
      enabled: false,
    },
    etherscan: {
      enabled: false,
    },
    sourcify: {
      enabled: true,
    },
  },
});
