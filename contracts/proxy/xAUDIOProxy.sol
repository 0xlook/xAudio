pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract xAUDIOProxy is TransparentUpgradeableProxy {
    constructor(address _logic, address _proxyAdmin) TransparentUpgradeableProxy(_logic, _proxyAdmin, "") {}
}
