const { ZERO_ADDRESS } = require("@openzeppelin/test-helpers/src/constants")
const { artifacts } = require("hardhat")
const deploymentHelper = require("./../../utils/deploymentHelpers.js")
const testHelpers = require("./../../utils/testHelpers.js")
const th = testHelpers.TestHelper
const dec = th.dec
const toBN = th.toBN
const timeValues = testHelpers.TimeValues


const OhmOracle = artifacts.require('GOHMOracleAdapter.sol')
const BTCOracle = artifacts.require('OracleAdapter.sol')
const BAMM = artifacts.require('BAMM.sol')
const Token = artifacts.require("VSTToken")
const BorrowOps = artifacts.require("BorrowerOperations.sol")
let ohmOracle
let btcOracle
let ethOracle

let bammEth
let bammBtc
let bammOhm

contract('BAMM', async accounts => {
  const whale = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
  const renBtcWhale = "0x8c80c1FE10912398Bf0FE68A25839DefCaef588e"
  const ohmWhale = "0x3a3814829aEff40Fb9Ad0bf35A8df23743e94163"
  const deployer = "0x23cBF6d1b738423365c6930F075Ed6feEF7d14f3"

  describe("BAMM", async () => {

    before(async () => {
      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [whale],
      });

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [renBtcWhale],
      });
      
      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [ohmWhale],
      });      

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [deployer],
      });           

      const ohmV2 = "0x761aaeBf021F19F198D325D7979965D0c7C9e53b"
      const ohmIndex = "0x48C4721354A3B29D80EF03C65E6644A37338a0B1"

      ohmOracle = await OhmOracle.new(ohmIndex, ohmV2, {from: whale})
      console.log("ohm oracle address", ohmOracle.address)

      btcOracle = await BTCOracle.new("0x6ce185860a4963106506C203335A2910413708e9", 8)
      console.log("btcOracle oracle address", btcOracle.address)

      ethOracle = await BTCOracle.new("0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612", 18)
      console.log("ethOracle oracle address", ethOracle.address)

      const renbtc = "0xDBf31dF14B66535aF65AaC99C32e9eA844e14501"
      const gohm = "0x8D9bA570D6cb60C7e3e0F31343Efe75AB8E65FB1"
      const eth = "0x0000000000000000000000000000000000000000"

      const feePool = "0xf2bb803010FA55ab60aF1a4740d1A1D6c9C93a39"      
      const frontEndTag = eth

      const ethSp = "0x64cA46508ad4559E1fD94B3cf48f3164B4a77E42"
      const renBtcSp = "0x3282dfAf0fBba4d3E771C4E5F669Cb4E14D8adb0"
      const ohmSp = "0x6e53D20d674C27b858a005Cf4A72CFAaf4434ECB"

      const lusd = "0x64343594Ab9b56e99087BfA6F2335Db24c2d1F17"
      const lqty = "0xa684cd057951541187f288294a1e1C2646aA2d24"

      bammEth = await BAMM.new(ethOracle.address, ethSp, lusd, lqty, eth, 400, feePool, frontEndTag, {from: whale})
      console.log("bamm eth", bammEth.address)

      bammBtc = await BAMM.new(btcOracle.address, renBtcSp, lusd, lqty, renbtc, 400, feePool, frontEndTag, {from: whale})
      console.log("bammBtc", bammBtc.address)
      
      bammOhm = await BAMM.new(ohmOracle.address, ohmSp, lusd, lqty, gohm, 400, feePool, frontEndTag, {from: whale})
      console.log("bammOhm", ohmOracle.address)


      // send some lambos to bamms
      const btc = await Token.at(renbtc)
      const ohm = await Token.at(gohm)

      await web3.eth.sendTransaction({from: whale, to: bammEth.address, value: toBN(dec(1, 18))})
      await btc.transfer(bammBtc.address, toBN(dec(1,8)), {from: renBtcWhale})
      await ohm.transfer(bammOhm.address, toBN(dec(1,18)), {from: ohmWhale})



      console.log("try to open trove")
      const borrowOperationAddress = "0x3eEDF348919D130954929d4ff62D626f26ADBFa2"
      const borrowOps = await BorrowOps.at(borrowOperationAddress)
      await borrowOps.openTrove(ZERO_ADDRESS, dec(4,17), dec(1,16), dec(801, 18), ZERO_ADDRESS,ZERO_ADDRESS, {from: deployer, value:dec(4,17)})
/*
      openTrove(
        address _asset,
        uint256 _tokenAmount,
        uint256 _maxFeePercentage,
        uint256 _VSTAmount,
        address _upperHint,
        address _lowerHint      
*/
      console.log("success")
      const lusdToken = await Token.at(lusd)
      console.log((await lusdToken.balanceOf(whale)).toString())
    })

    beforeEach(async () => {
    })

    // --- provideToSP() ---
    // increases recorded LUSD at Stability Pool
    it("get price ohm", async () => {
      console.log("checking decimals")
      const decimals = await ohmOracle.decimals()      
      console.log(decimals.toString())
      console.log("checking price")
      const roundData = await ohmOracle.latestRoundData()
      console.log(roundData.answer.toString())

      console.log("ohm fetch price", (await bammOhm.fetchPrice()).toString())
      const value = (await bammOhm.getCollateralValue()).value
      console.log("collateralValue", value.toString())      
    })

    it("get price ren btc", async () => {
      console.log("checking decimals")
      const decimals = await btcOracle.decimals()      
      console.log(decimals.toString())
      console.log("checking price")
      const roundData = await btcOracle.latestRoundData()
      console.log(roundData.answer.toString())

      console.log("btc fetch price", (await bammBtc.fetchPrice()).toString())      
      const value = (await bammBtc.getCollateralValue()).value
      console.log("collateralValue", value.toString())          
    })
    
    it("get price eth", async () => {
      console.log("checking decimals")
      const decimals = await ethOracle.decimals()      
      console.log(decimals.toString())
      console.log("checking price")
      const roundData = await ethOracle.latestRoundData()
      console.log(roundData.answer.toString())

      console.log("eth fetch price", (await bammEth.fetchPrice()).toString())      
      const value = (await bammEth.getCollateralValue()).value
      console.log("collateralValue", value.toString())           
    })    
  })
})


function almostTheSame(n1, n2) {
  n1 = Number(web3.utils.fromWei(n1))
  n2 = Number(web3.utils.fromWei(n2))
  //console.log(n1,n2)

  if(n1 * 1000 > n2 * 1001) return false
  if(n2 * 1000 > n1 * 1001) return false  
  return true
}

function in100WeiRadius(n1, n2) {
  const x = toBN(n1)
  const y = toBN(n2)

  if(x.add(toBN(100)).lt(y)) return false
  if(y.add(toBN(100)).lt(x)) return false  
 
  return true
}

async function assertRevert(txPromise, message = undefined) {
  try {
    const tx = await txPromise
    // console.log("tx succeeded")
    assert.isFalse(tx.receipt.status) // when this assert fails, the expected revert didn't occur, i.e. the tx succeeded
  } catch (err) {
    // console.log("tx failed")
    assert.include(err.message, "revert")
    
    if (message) {
       assert.include(err.message, message)
    }
  }
}
