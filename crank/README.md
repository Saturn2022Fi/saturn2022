# Crank

The vault's hands. Settles options past expiry, writes fresh ones against free
stock, folds arrived premiums into the per-share total. It decides nothing about
price: premiums are computed on chain when a buyer pays, so a wrong number here
buys nobody anything.

```
CRANK_KEY=0x...   the vault's keeper key
VAULTS=0xD9b2CA7B0Edf837e385eA71481fd3E931CA5500F,0x00797840bd317A6a2812f30270d039BDd50F0257,0x7177d72FDFCADbE2555691b6Af49784F27aD8991,0xd91b736Af26182c83c41BF22904e290441e888eB,0xe581a9708a9874914748DbD37Dc49db09B946aE1,0x27aeB9B6F6E27090f754A4050c9226999ceaC189,0x316F86739F33337d74d32e50Ea54bced85bFE2dC,0xE8D4f7e52B4A6e61DeF6a9586E4Fdd667B04358F,0xd1B36e27cfCD41c6015eE6BC4De64C9AA2AAc9fb,0x0750e9d485aC7B395d6852DefEff1EbfA94EEf79,0x1a383e52571E3Dc9612616fa36Ab47c99C6dff58,0xD07f9ca7e91efd441AF313a11C8cb22bfE9d2F47,0xdC9a6e54Aa60Bd12E98A1F799c002b06c5AA32c9,0x02fD686be905ad3908d783f773264Da076132DD3,0x2BAa963e1656665567295bA282555542694b544a,0xa10661E584B28436E1c30Fad9727281678cfDfB0,0x47ACfcf918edf327477a58952468eBb4109140A7
STRIKE_BPS=11000  strike at 110% of spot
TENOR_DAYS=7
INTERVAL_SEC=3600
DRY_RUN=1         decide and print, never send
```

```
npm install
DRY_RUN=1 npm run once      # one pass, nothing sent
npm start                   # the loop
```

The key can do two things, write and settle, and both move assets only between
the vault and the house. A stolen crank key can write badly-struck options; it
cannot take a share.
