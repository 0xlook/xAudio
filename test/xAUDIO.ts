import hre, { ethers } from "hardhat";
import { Artifact } from "hardhat/types";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { BigNumber } from "@ethersproject/bignumber";
import { expect } from "chai";
import { Signer } from "ethers";
import { unlockAccount, ether, getBlockNumber, mineBlocks } from "./utils";
import { XAUDIO, XAUDIOProxy, MockERC20, IClaimManager } from "../typechain";

const { deployContract } = hre.waffle;

describe("xAUDIO Test", () => {
  let xAUDIO: XAUDIO;
  let xAUDIOProxy: XAUDIOProxy;
  let xAUDIOProxyCast: XAUDIO;
  let audioContract: MockERC20;
  let claimManager: IClaimManager;
  let owner: SignerWithAddress;
  let multisig: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let whale: Signer;
  const audio = "0x18aAA7115705e8be94bfFEBDE57Af9BFc265B998";
  const serviceProvider = "0xA9cB9d043d4841dE83C70556FF0Bd4949C15b5Eb"; // Alt Ego
  const delegateManger = "0x4d7968ebfD390D5E7926Cb3587C39eFf2F9FB225";
  const claimManagerAddress = "0x44617F9dCEd9787C3B06a05B35B4C779a2AA1334";
  const symbol = "XAUDIO";
  const INITIAL_SUPPLY_MULTIPLIER = BigNumber.from(100);
  const AUDIO_BUFFER_TARGET = BigNumber.from(20);
  const unDelegateLockUp = 46523;

  before(async () => {
    const signers: SignerWithAddress[] = await hre.ethers.getSigners();

    owner = signers[0];
    multisig = signers[1];
    alice = signers[2];
    bob = signers[3];

    const xAUDIOArtifact: Artifact = await hre.artifacts.readArtifact("xAUDIO");
    xAUDIO = <XAUDIO>await deployContract(owner, xAUDIOArtifact);
    const xAUDIOProxyArtifact: Artifact = await hre.artifacts.readArtifact("xAUDIOProxy");
    xAUDIOProxy = <XAUDIOProxy>await deployContract(owner, xAUDIOProxyArtifact, [xAUDIO.address, multisig.address]);
    xAUDIOProxyCast = <XAUDIO>await ethers.getContractAt(xAUDIOArtifact.abi, xAUDIOProxy.address);
    const claimManagerArtifact: Artifact = await hre.artifacts.readArtifact("IClaimManager");
    claimManager = <IClaimManager>await ethers.getContractAt(claimManagerArtifact.abi, claimManagerAddress);

    await xAUDIOProxyCast.connect(owner).initialize(audio, serviceProvider, delegateManger, symbol);

    const erc20Artifacts: Artifact = await hre.artifacts.readArtifact("MockERC20");
    audioContract = <MockERC20>await ethers.getContractAt(erc20Artifacts.abi, audio);

    await unlockAccount("0x9416fd2bc773c85a65d699ca9fc9525f1424df94");
    whale = await ethers.provider.getSigner("0x9416fd2bc773c85a65d699ca9fc9525f1424df94");
    await owner.sendTransaction({
      to: "0x9416fd2bc773c85a65d699ca9fc9525f1424df94",
      value: ether("1"),
    });

    await audioContract.connect(whale).transfer(alice.address, ether("10000"));
    await audioContract.connect(whale).transfer(bob.address, ether("10000"));
  });

  describe("mintWithToken", async () => {
    let totalAmount = ether(0);
    let totalMint = ether(0);

    before(async () => {
      await audioContract.connect(alice).approve(xAUDIOProxyCast.address, ether(1000));
      await audioContract.connect(bob).approve(xAUDIOProxyCast.address, ether(1000));
    });

    beforeEach(async () => {});

    it("alice mint: fail when less than minDelegate", async () => {
      const amount = ether(10);

      await expect(xAUDIOProxyCast.connect(alice).mintWithToken(amount)).to.be.revertedWith(
        "Must send > minDelegateAmount",
      );
    });

    it("alice mint: should success with enough audio amount", async () => {
      const amount = ether("110");

      await xAUDIOProxyCast.connect(alice).mintWithToken(amount);
      const aliceBalance = await xAUDIOProxyCast.balanceOf(alice.address);
      expect(aliceBalance).to.equal(amount.mul(INITIAL_SUPPLY_MULTIPLIER));

      totalAmount = totalAmount.add(amount);
      totalMint = totalMint.add(aliceBalance);

      const stakedBalance = await xAUDIOProxyCast.getStakedBalance();
      expect(stakedBalance).to.equal(amount.sub(amount.div(AUDIO_BUFFER_TARGET)));
    });

    it("bob mint: should success", async () => {
      const amount = ether("10");

      await xAUDIOProxyCast.connect(bob).mintWithToken(amount);
      const bobBalance = await xAUDIOProxyCast.balanceOf(bob.address);
      expect(bobBalance).to.equal(amount.mul(totalMint).div(totalAmount));

      totalMint = totalMint.add(bobBalance);
      totalAmount = totalAmount.add(amount);

      const stakedBalance = await xAUDIOProxyCast.getStakedBalance();
      expect(stakedBalance).to.equal(totalAmount.sub(totalAmount.div(AUDIO_BUFFER_TARGET)));
    });
  });

  describe("claimReward", async () => {
    before(async () => {
      const blockNumber = await getBlockNumber();
      const lastFundedBlock = await claimManager.getLastFundedBlock();
      const fundRoundBlockDiff = await claimManager.getFundingRoundBlockDiff();
      const blockToMine = lastFundedBlock.toNumber() + fundRoundBlockDiff.toNumber() - blockNumber;

      await mineBlocks(blockToMine);

      await claimManager.connect(owner).initiateRound();
    });

    it("should claim reward and increase staked balance", async () => {
      const stakedBalance = await xAUDIOProxyCast.getStakedBalance();
      await xAUDIOProxyCast.connect(owner).claimRewards();
      const newBalance = await xAUDIOProxyCast.getStakedBalance();
      expect(newBalance.gt(stakedBalance)).to.equal(true);
    });
  });

  describe("unstack", async () => {
    const amount = ether(10);

    it("start cooldown", async () => {
      await xAUDIOProxyCast.connect(owner).cooldown(amount);
      await mineBlocks(unDelegateLockUp);
    });

    it("unstack", async () => {
      const stakedBalance = await xAUDIOProxyCast.getStakedBalance();
      const bufferBalance = await xAUDIOProxyCast.getBufferBalance();

      await xAUDIOProxyCast.connect(owner).unstake();

      const newStakedBalance = await xAUDIOProxyCast.getStakedBalance();
      const newBufferBalance = await xAUDIOProxyCast.getBufferBalance();

      expect(stakedBalance).to.equal(newStakedBalance.add(amount));
      expect(newBufferBalance).to.equal(bufferBalance.add(amount));
    });
  });
});
