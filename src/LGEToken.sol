// SPDX-License-Identifier:
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";

contract LGEToken is ERC20, ERC20Burnable, ERC20Capped {
    uint256 public constant TOTAL_SUPPLY = 17_745_440_000e18;

    address private _admin;
    address private _factory;
    address private _hook;

    string private _metadata;
    string private _image;

    error NotAdmin();
    error NotFactory();
    error NotHook();

    event UpdateImage(string image);
    event UpdateMetadata(string metadata);
    event Mint(address to, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        string memory image_,
        string memory metadata_,
        address factory_
    ) ERC20(name_, symbol_) ERC20Capped(TOTAL_SUPPLY) {
        _admin = admin_;
        _image = image_;
        _metadata = metadata_;
        _factory = factory_;
    }

    function setMinter(address minter) external {
        if (msg.sender != _factory) {
            revert NotFactory();
        }
        _hook = minter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != _hook) {
            revert NotHook();
        }
        _mint(to, amount);

        emit Mint(to, amount);
    }

    function updateImage(string memory image_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        _image = image_;
        emit UpdateImage(image_);
    }

    function updateMetadata(string memory metadata_) external {
        if (msg.sender != _admin) {
            revert NotAdmin();
        }
        _metadata = metadata_;
        emit UpdateMetadata(metadata_);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }

    function admin() external view returns (address) {
        return _admin;
    }

    function imageUrl() external view returns (string memory) {
        return _image;
    }

    function metadata() external view returns (string memory) {
        return _metadata;
    }
}
