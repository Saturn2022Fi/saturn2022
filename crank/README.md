# Crank

The vault's hands. Settles options past expiry, writes fresh ones against free
stock, folds arrived premiums into the per-share total. It decides nothing about
price: premiums are computed on chain when a buyer pays, so a wrong number here
buys nobody anything.

```
CRANK_KEY=0x...   the vault's keeper key
VAULTS=0x7207EBc7493F66f62166fb951F14bB333C06297C,0x2Fbd30388365e1fD540BfE50CaF9cd995f068978,0xAfAB96AAc9FcB0f201582F00c17FcBb3090BF03C,0xc3bafEEbD3709eC6F7D284DDF63D91E80FB2041E,0x3F5Ac1ef5a9388F4f1fe76890A4bbDE15ebA53b1,0x369A3BeCe8C88F3933C5d5Eb3Ba2092dF98CE0E2,0x7C00D9BF8654E9711608e14F57C8e42EF2c35EA4,0x1Bb0AA34905230582Ef754d94376704B7442D173,0xF62F9d8A3c2c8F38b599901F5742fd2E64F20215,0x1fDC0DD9080a7eE8411F7bF9344170147b048602,0x1748b1fd8E309c75C6A684A2073d061Cccac6fe0,0x6Fb56FbB571914e2c19F5E6cCD38ae0A77Ac4bFe,0x776a20db2E6461A41f90582cC4D03D4c13e1fD56,0x0780c57eE890778e4C5798fd64d5b470a7214438,0x84CA400689594a8E157E98f647b63Cab01c2f52d,0xf4cf2b4cd511c1280Fa56ff1964773A8De94bf04,0xD72E6FFc31A923D0928a96736be98B8090769044
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
