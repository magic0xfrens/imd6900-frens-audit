// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenArt} from "../../src/frens/FrenRenderer.sol";

/// @dev The launch trait rules, shared by the tests: mumu and bobo from tier 2, laser eyes and the lightsabers tier 3,
///      gold lens / gold coat / hats / most items tier 1, a gold-coat mumu or bobo tier 3. The deploy script sets the
///      same (script/frens/DeployFrens.s.sol).
abstract contract FrensRules {
    uint8 internal constant PEPE = 0;
    uint8 internal constant MUMU = 1;
    uint8 internal constant BOBO = 2;
    uint8 internal constant LASER = 12; // face
    uint8 internal constant GOLD = 2; // coat
    uint8 internal constant SABER = 12; // item: the green lightsaber

    function _fill(uint8 n, uint16 cap, uint8 tier) internal pure returns (uint16[] memory caps, uint8[] memory tiers) {
        caps = new uint16[](n);
        tiers = new uint8[](n);
        for (uint8 i; i < n; ++i) {
            caps[i] = cap;
            tiers[i] = tier;
        }
    }

    function _rules(IMD6900Frens f, uint16[3] memory chars) internal {
        (uint16[] memory c, uint8[] memory t) = _fill(3, 0, 0);
        (c[0], c[1], c[2]) = (chars[0], chars[1], chars[2]);
        (t[1], t[2]) = (2, 2);
        f.setTraitRules(0, c, t);
        (c, t) = _fill(13, 2222, 0);
        (c[LASER], t[LASER]) = (56, 3);
        f.setTraitRules(1, c, t);
        (c, t) = _fill(4, 2222, 0);
        (c[3], t[3]) = (222, 1);
        f.setTraitRules(2, c, t);
        (c, t) = _fill(3, 2222, 0);
        (c[GOLD], t[GOLD]) = (103, 1);
        f.setTraitRules(3, c, t);
        (c, t) = _fill(6, 2222, 0);
        f.setTraitRules(4, c, t);
        (c, t) = _fill(3, 266, 1);
        (c[0], t[0]) = (2222, 0);
        f.setTraitRules(5, c, t);
        (c, t) = _fill(10, 2222, 0);
        f.setTraitRules(6, c, t);
        (c, t) = _fill(16, 140, 1);
        (c[0], t[0]) = (2222, 0);
        for (uint256 i; i < 6; ++i) t[[1, 3, 4, 10, 11, 14][i]] = 0; // the common items
        (c[12], t[12], c[13], t[13]) = (56, 3, 56, 3); // the lightsabers
        f.setTraitRules(7, c, t);
        f.addPairRule(IMD6900Frens.PairRule(0, MUMU, 3, GOLD, 3));
        f.addPairRule(IMD6900Frens.PairRule(0, BOBO, 3, GOLD, 3));
    }

    /// @dev A price table where every fren costs 0.69 $IMD (6900 units of 0.0001): the tests' arithmetic stays simple
    function _flatPrices() internal returns (address) {
        bytes[] memory b = new bytes[](1);
        b[0] = new bytes(3 * 2222);
        for (uint256 i; i < 2222; ++i) (b[0][3 * i + 1], b[0][3 * i + 2]) = (0x1a, 0xf4);
        return new FrenArt().write(b)[0];
    }

    function _combo(uint8 ch, uint8 face, uint8 eye, uint8 coat, uint8 shirt, uint8 hat, uint8 bg, uint8 item)
        internal
        pure
        returns (uint24)
    {
        return uint24(
            uint256(ch) | uint256(face) << 2 | uint256(eye) << 6 | uint256(coat) << 8 | uint256(shirt) << 10
                | uint256(hat) << 13 | uint256(bg) << 15 | uint256(item) << 19
        );
    }
}
