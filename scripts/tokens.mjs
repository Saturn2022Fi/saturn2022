// Addresses read off chain, not typed from a screenshot. Robinhood publishes the
// canonical list at docs.robinhood.com/chain/contracts; dozens of impostor
// tokens share these tickers, so an address that did not come from the registry
// is not the asset it says it is.

export const STOCKS = {
  AAPL: "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9",
  AMD: "0x86923f96303d656e4aa86d9d42d1e57ad2023fdc",
  AMZN: "0x12f190a9f9d7d37a250758b26824b97ce941bf54",
  BE: "0x822cc93ffd030293e9842c30bbd678f530701867",
  COIN: "0x6330d8c3178a418788df01a47479c0ce7ccf450b",
  CRWV: "0x5f10a1c971b69e47e059e1dc91901b59b3fb49c3",
  GOOGL: "0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3",
  INTC: "0xc72b96e0e48ecd4dc75e1e45396e26300bc39681",
  META: "0xc0d6457c16cc70d6790dd43521c899c87ce02f35",
  MSFT: "0xe93237c50d904957cf27e7b1133b510c669c2e74",
  MU: "0xff080c8ce2e5feadaca0da81314ae59d232d4afd",
  NVDA: "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec",
  ORCL: "0xb0992820e760d836549ba69bc7598b4af75dee03",
  PLTR: "0x894e1ec2d74ffe5aef8dc8a9e84686accb964f2a",
  SNDK: "0xb90a19ff0af67f7779aff50a882a9cff42446400",
  SPCX: "0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea",
  TSLA: "0x322f0929c4625ed5bad873c95208d54e1c003b2d",
  USAR: "0xd917b029c761d264c6a312bbbcda868658ef86a6",
  SPY: "0x117cc2133c37b721f49de2a7a74833232b3b4c0c",
  SGOV: "0x92fd66527192e3e61d4ddd13322aa222de86f9b5",
  SCHD: "0xd63abb2c13d7a8421a8017a712802053568e3c1d",
  JNJ: "0x03dfbbe0ac4e7bcdafd08ed41a400326b77d8c80",
  XOM: "0xf9b46d3d1b22199d4d1025a9ced b540a33f1a2d5".replace(/\s/g, ""),
};

export const CORE = {
  USDG: "0x5fc5360d0400a0fd4f2af552add042d716f1d168",
  WETH: "0x0bd7d308f8e1639fab988df18a8011f41eacad73",
  uniswapV4PoolManager: "0x8366a39cc670b4001a1121b8f6a443a643e40951",
  universalRouter: "0xe28c0e44f4016b073db20cf28971cac6ce3664d3",
};

/** The one private company on the chain, and the reason some people are here. */
export const PRIVATE = ["SPCX"];
