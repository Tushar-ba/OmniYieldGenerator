const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MyOFT", (m) => {
  // Get the LayerZero endpoint address for the current network
  const lzEndpoint = m.getParameter("lzEndpoint");
  const delegate = m.getParameter("delegate");
  const name = m.getParameter("name", "My Omnichain Token");
  const symbol = m.getParameter("symbol", "MOT");

  const myOFT = m.contract("MyOFT", [name, symbol, lzEndpoint, delegate]);

  return { myOFT };
}); 