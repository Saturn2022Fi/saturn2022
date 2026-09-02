// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";

/// The house with the same seventeen listings the live one carries, then a
/// vault per market. Two keys: the house is listed by the deployer key, the
/// vaults are owned and kept by the keeper key the crank runs.
///
///   HOUSE_KEY=... VAULT_KEY=... forge script script/Deploy.s.sol \
///     --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast --slow
contract Deploy is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint16 constant MARKUP = 3000;

    function markets() internal pure returns (OptionHouse.Market[] memory ms) {
        ms = new OptionHouse.Market[](17);
        ms[0] = OptionHouse.Market(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb, 5395404172112830, MARKUP);
        ms[1] = OptionHouse.Market(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15, 5206942968134557, MARKUP);
        ms[2] = OptionHouse.Market(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0x4A1166a659A55625345e9515b32adECea5547C38, 5390479861635596, MARKUP);
        ms[3] = OptionHouse.Market(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0, 5244263305721928, MARKUP);
        ms[4] = OptionHouse.Market(0xe93237C50D904957Cf27E7B1133b510C669c2e74, 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E, 5267189469728268, MARKUP);
        ms[5] = OptionHouse.Market(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 0x7C38C00C30BEe9378381E7B6135d7283356D71b1, 5166862735098046, MARKUP);
        ms[6] = OptionHouse.Market(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0xF6f373a037c30F0e5010d854385cA89185AE638b, 5195878348344150, MARKUP);
        ms[7] = OptionHouse.Market(0x12f190a9F9d7D37a250758b26824B97CE941bF54, 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C, 5283195262066849, MARKUP);
        ms[8] = OptionHouse.Market(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596, 5372804508990962, MARKUP);
        ms[9] = OptionHouse.Market(0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c, 5462123515107771, MARKUP);
        ms[10] = OptionHouse.Market(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72, 5342825341723010, MARKUP);
        ms[11] = OptionHouse.Market(0xc72b96e0E48ecd4DC75E1e45396e26300BC39681, 0x3f390C5C24628Ac7C489515402235FeAD71D1913, 5290437296935930, MARKUP);
        ms[12] = OptionHouse.Market(0xb0992820E760d836549ba69BC7598b4af75dEE03, 0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844, 5422538519903522, MARKUP);
        ms[13] = OptionHouse.Market(0xB90A19fF0Af67f7779afF50A882A9CfF42446400, 0xfb133Fa4B7b385802B693a293606682Df47109A3, 5488052450720371, MARKUP);
        ms[14] = OptionHouse.Market(0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3, 0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C, 5283352724441065, MARKUP);
        ms[15] = OptionHouse.Market(0xd917B029C761D264c6A312BBbcDA868658eF86a6, 0x451B1295aA84FD6d6b58af1a5002eA1b1A1913A0, 5898988585151369, MARKUP);
        ms[16] = OptionHouse.Market(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 0x319724394D3A0e3669269846abE664Cd621f9f6A, 5077519184225917, MARKUP);
    }

    function names() internal pure returns (string[17] memory n, string[17] memory s) {
        n[0] = "Saturn SpaceX Covered Call";        s[0] = "sSPCX";
        n[1] = "Saturn NVIDIA Covered Call";        s[1] = "sNVDA";
        n[2] = "Saturn Tesla Covered Call";         s[2] = "sTSLA";
        n[3] = "Saturn Apple Covered Call";         s[3] = "sAAPL";
        n[4] = "Saturn Microsoft Covered Call";     s[4] = "sMSFT";
        n[5] = "Saturn Meta Covered Call";          s[5] = "sMETA";
        n[6] = "Saturn Alphabet Covered Call";      s[6] = "sGOOGL";
        n[7] = "Saturn Amazon Covered Call";        s[7] = "sAMZN";
        n[8] = "Saturn Micron Covered Call";        s[8] = "sMU";
        n[9] = "Saturn Palantir Covered Call";      s[9] = "sPLTR";
        n[10] = "Saturn AMD Covered Call";          s[10] = "sAMD";
        n[11] = "Saturn Intel Covered Call";        s[11] = "sINTC";
        n[12] = "Saturn Oracle Covered Call";       s[12] = "sORCL";
        n[13] = "Saturn Sandisk Covered Call";      s[13] = "sSNDK";
        n[14] = "Saturn CoreWeave Covered Call";    s[14] = "sCRWV";
        n[15] = "Saturn USA Rare Earth Covered Call"; s[15] = "sUSAR";
        n[16] = "Saturn S&P 500 Covered Call";      s[16] = "sSPY";
    }

    function run() external {
        (string[17] memory n, string[17] memory s) = names();

        vm.startBroadcast(vm.envUint("HOUSE_KEY"));
        OptionHouse house = new OptionHouse(USDG, markets());
        vm.stopBroadcast();
        console2.log("house", address(house));

        vm.startBroadcast(vm.envUint("VAULT_KEY"));
        for (uint256 i = 0; i < 17; i++) {
            CoveredCallVault v = new CoveredCallVault(house, uint32(i), n[i], s[i]);
            console2.log(s[i], address(v));
        }
        vm.stopBroadcast();
    }
}
