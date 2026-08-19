import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

// Deployers
// 0x99DBD6ec3111948b8fC97Eb7e080Ad6FC9E78368 (Mainnet)
// 0xbb7588f2c0DE4421a610CA1CAF168c0EC9838B4b (Testnet)
const DividendAllTokenModule = buildModule("DividendAllTokenModule", (m) => {
  // ============================================================
  // Basic token configuration
  // ============================================================

  const name = m.getParameter("name", "My Dividend Token");
  const symbol = m.getParameter("symbol", "MDT");
  const decimals = m.getParameter("decimals", 18);

  // IMPORTANT:
  // totalSupply is the human-readable amount.
  // Your contract multiplies it by 10 ** decimals.
  //
  // Example:
  // 1,000,000,000 tokens with 18 decimals
  // => 1_000_000_000 * 10^18
  const totalSupply = m.getParameter(
    "totalSupply",
    1_000_000_000n
  );

  // ============================================================
  // Addresses
  // ============================================================

  const receiveAddress = m.getParameter(
    "receiveAddress",
    "0x99DBD6ec3111948b8fC97Eb7e080Ad6FC9E78368"
    // "0xcF981707674499499c035dc7b5Fc8544f981e09F"
  );

  const fundAddress = m.getParameter(
    "fundAddress",
    "0xBA040759378D1e0ef1FeBBa25597EE40963E3596"
  );

  const swapRouter = m.getParameter(
    "swapRouter",
    "0x89e5DB8B5aA49aA85AC63f691524311AEB649eba"
  );

  const basePoolToken = m.getParameter(
    "basePoolToken",
    "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73" // WETH
  );

  // ============================================================
  // Tax configuration
  //
  // Values are basis points.
  //
  // 100   = 1%
  // 250   = 2.5%
  // 1000  = 10%
  // ============================================================

  const buyRates = m.getParameter(
    "buyRates",
    [
      100n, // buyFund
      0n, // buyLP
      0n, // buyBurn
      400n, // buyDividend = 4%
    ]
  );

  const sellRates = m.getParameter(
    "sellRates",
    [
      100n, // sellFund
      0n, // sellLP
      0n, // sellBurn
      400n, // sellDividend = 4%
    ]
  );

  const transferRates = m.getParameter(
    "transferRates",
    [
      0n, // transferFund
      0n, // transferLP
      0n, // transferBurn
      0n, // transferDividend
    ]
  );

  // ============================================================
  // Dividend configuration
  // ============================================================

  const minHoldingForDividend = m.getParameter(
    "minHoldingForDividend",
    20_000n
  );

  const dividendTriggerThreshold = m.getParameter(
    "dividendTriggerThreshold",
    2_500_000n
  );

  const autoProcessGasLimit = m.getParameter(
    "autoProcessGasLimit",
    50_000_000n
  );

  // ============================================================
  // Trading configuration
  // ============================================================

  const killBlockCount = m.getParameter(
    "killBlockCount",
    0n
  );

  const mintEnabled = m.getParameter(
    "mintEnabled",
    false
  );

  const manualTradingEnable = m.getParameter(
    "manualTradingEnable",
    false
  );

  const blacklistEnabled = m.getParameter(
    "blacklistEnabled",
    false
  );

  const whitelistEnabled = m.getParameter(
    "whitelistEnabled",
    true
  );

  // ============================================================
  // Initial lists
  // ============================================================

  const initialBlacklist = m.getParameter(
    "initialBlacklist",
    []
  );

  const initialWhitelist = m.getParameter(
    "initialWhitelist",
    []
  );

  // ============================================================
  // Dividend mode
  // ============================================================

  // false = reward-token dividend
  // true  = same-token dividend
  const isSameTokenDividend = m.getParameter(
    "isSameTokenDividend",
    false
  );

  //
  // If isSameTokenDividend = false:
  // dividendToken MUST be a valid token address
  //
  // If isSameTokenDividend = true:
  // dividendToken can be address(0) or the token itself.
  //
  const dividendToken = m.getParameter(
    "dividendToken",
    "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
  );

  // ============================================================
  // Constructor parameters
  // ============================================================

  const token = m.contract("DividendAllToken", [
    {
      name,
      symbol,
      decimals,
      totalSupply,

      receiveAddress,
      fundAddress,
      swapRouter,
      basePoolToken,

      buyRates,
      sellRates,
      transferRates,

      minHoldingForDividend,
      dividendTriggerThreshold,
      autoProcessGasLimit,

      killBlockCount,

      mintEnabled,
      manualTradingEnable,

      blacklistEnabled,
      whitelistEnabled,

      initialBlacklist,
      initialWhitelist,

      isSameTokenDividend,
      dividendToken,
    },
  ]);

  return {
    token,
  };
});

export default DividendAllTokenModule;