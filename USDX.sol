pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title USDX - Settlement and Collateral Token
/// @notice USDX is an Internal accounting token used only for settlement and collateral
///  within the RealHedge platform. Not a public sale / speculative token.
contract USDX is ERC20, Ownable {
    uint8 private constant _DECIMALS = 18;

    constructor(uint256 initialSupply) ERC20("RealHedge USDX", "USDX") Ownable(msg.sender) {
        // Demo environment default: 1,000,000 USDX
        _mint(msg.sender, initialSupply * 10 ** _DECIMALS);
    }

    /// @notice Mint is Restricted to the owner (e.g. the platform deployer)
    ///       since USDX is not   meant to be freely mintable or traded.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Convenience faucet so demo/test wallets can self-fund without
    ///         needing the owner key. Capped per call to discourage misuse.
    function faucet(uint256 amount) external {
        require(amount <= 10_000 * 10 ** _DECIMALS, "USDX: faucet cap exceeded");
        _mint(msg.sender, amount);
    }
}
