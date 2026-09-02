# Crank

The vault's hands. Settles options past expiry, writes fresh ones against free
stock, folds arrived premiums into the per-share total. It decides nothing about
price: premiums are computed on chain when a buyer pays, so a wrong number here
buys nobody anything.

```
CRANK_KEY=0x...   the vault's keeper key
VAULTS=0xe3F851a97683EB8cCBcc8c74Dc3b62bE55e9D966,0x313E8f7c997454eCfBB81868852451597d8a3F5F,0x3c4Bf690d5F83824BA4820DC0d6C2Fa591FE8540,0xA834AB4784dB4D6868232bb92566931D8398a44a,0x2764281bd32DCb88bb799D0F5114571c7226e5a2,0x8A04b77A203664670d1F8d97285057a23BA402f4,0xEB0a8EF88812Ea40135086ce71243B0D26B83BAe,0x68c68D8beF118923164362bD12685A8Dfe0d0027,0xc29E48962BdbaD59c6531Bc47AEc8E894259365c,0xB0d505B72B6Ff3B881daDa77A58F8631cf5ff350,0x77CDcb167537890C4651BF8f9602f00BCa47641F,0x8Db357ABC9cD98624D88A8E0b5Eeb65d7bEd6AB7,0xedd9B5bcDe7E8d47Da4E68824e07699aBA9069cb,0xFD24E4E353F22b62f44D61CD91Ea80eEee7C3d4a,0x380D2b1978578A44595eBb24a3e7F3532370c82e,0x905D6bcbb30Dfe6A32576829BE631cb0a9DFa185,0x7AfA4eeb6E42C49116491bf6292A8429E2D13332
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
