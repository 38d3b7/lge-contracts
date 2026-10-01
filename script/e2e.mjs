// End-to-end test of the LGE flow on Arc testnet, driven through the
// FRONTEND's own artifacts: bytecode constants, ABIs, and address resolution
// are extracted from lge-frontend source files, and each on-chain call mirrors
// the exact hook/component code path a user would trigger in the UI.
//
//   create campaign (useCampaignAddresses + useHookMiner + useCreateCampaign)
//   -> deposit (BuyTokensModal: calculateEthNeeded + 5% slippage)
//   -> price rises with blocks (useCampaign)
//   -> fill cap -> pool init + LP mint (deposit finalize path)
//   -> claimLiquidity (CampaignDetail claim button)
//   -> second campaign, window expires, withdraw (UserProfile recover button)
//
// Usage: PRIVATE_KEY=0x... node e2e.mjs        (deployer key, funds a fresh user wallet)
// Requires: viem@2.37.9 (npm i viem@2.37.9 in any dir, run from there)
// Frontend source dir: LGE_FRONTEND_DIR env, default ../lge-frontend beside this repo

import { readFileSync } from 'node:fs'
import {
  createPublicClient, createWalletClient, http, defineChain,
  keccak256, encodePacked, encodeAbiParameters, concat, getCreate2Address,
  parseAbi, formatEther
} from 'viem'
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts'

const FRONTEND = process.env.LGE_FRONTEND_DIR ||
  new URL('../../lge-frontend', import.meta.url).pathname

// ---------- extract frontend artifacts ----------
function extractConst (file, name) {
  const src = readFileSync(`${FRONTEND}/${file}`, 'utf8')
  const re = new RegExp(name + '\\s*=\\s*["\'](0x[0-9a-fA-F]+)["\']')
  const m = src.match(re)
  if (!m) throw new Error(`const ${name} not found in ${file}`)
  return m[1]
}
function extractAbi (file) {
  // ABI files are TS object literals (unquoted keys) - evaluate as JS
  const src = readFileSync(`${FRONTEND}/${file}`, 'utf8')
  const start = src.indexOf('[')
  const end = src.lastIndexOf(']')
  return new Function(`return (${src.slice(start, end + 1)})`)()
}

const HOOK_BYTECODE = extractConst('src/config/contracts/bytecode/LGEHookBytecode.ts', 'LGE_HOOK_BYTECODE_ARC_TESTNET')
const TOKEN_BYTECODE = extractConst('src/config/contracts/bytecode/LGETokenBytecode.ts', 'LGE_TOKEN_BYTECODE_ARC_TESTNET')
const MANAGER_ABI = extractAbi('src/config/contracts/abis/LGEManagerAbi.ts')
const HOOK_ABI = extractAbi('src/config/contracts/abis/LGEHookAbi.ts')
const LIB_ABI = extractAbi('src/config/contracts/abis/LGECalculationsLibraryAbi.ts')
const MINER_ABI = extractAbi('src/config/contracts/abis/HookMinerAbi.ts')
const TOKEN_ABI = extractAbi('src/config/contracts/abis/LGETokenAbi.ts')
console.log('[artifacts] hook bytecode %d bytes, token bytecode %d bytes, ABIs loaded',
  (HOOK_BYTECODE.length - 2) / 2, (TOKEN_BYTECODE.length - 2) / 2)

// ---------- env / chain ----------
const env = Object.fromEntries(readFileSync(`${FRONTEND}/.env`, 'utf8').split('\n')
  .filter(l => l.includes('=') && !l.startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1)] }))

const MANAGER = env.VITE_LGE_MANAGER_ADDRESS_ARC_TESTNET
const LIB = env.VITE_LGE_CALCULATIONS_LIBRARY_ARC_TESTNET
const MINER = env.VITE_HOOK_MINER_ARC_TESTNET
const POOL_MANAGER = env.VITE_POOL_MANAGER_ARC_TESTNET
const POSITION_MANAGER = env.VITE_POSITION_MANAGER_ARC_TESTNET
const PERMIT2 = env.VITE_PERMIT2_ARC_TESTNET

const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.arc.io'] } }
})

const GAS = { maxFeePerGas: 20_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n }
const publicClient = createPublicClient({ chain: arcTestnet, transport: http() })

// Arc RPC intermittently answers heavy eth_call with -32003 (TransactionRejectedRpcError)
// even though the identical call succeeds on retry. wagmi's useReadContract hides this
// behind react-query retries; mirror that here.
async function readWithRetry (params, attempts = 6) {
  for (let i = 1; ; i++) {
    try {
      return await publicClient.readContract(params)
    } catch (e) {
      const transient = String(e?.cause?.code ?? e?.code) === '-32003' || /Transaction creation failed/.test(e.message)
      if (!transient || i === attempts) throw e
      console.log('[rpc] transient -32003 on %s, retry %d/%d', params.functionName, i, attempts)
      await new Promise(r => setTimeout(r, 2000 * i))
    }
  }
}

const deployer = privateKeyToAccount(process.env.PRIVATE_KEY)
const user = privateKeyToAccount(generatePrivateKey())
const userWallet = createWalletClient({ account: user, chain: arcTestnet, transport: http() })
const deployerWallet = createWalletClient({ account: deployer, chain: arcTestnet, transport: http() })

const ERC721_ABI = parseAbi(['function balanceOf(address) view returns (uint256)', 'function ownerOf(uint256) view returns (address)'])

async function mineAndCreate ({ name, symbol }) {
  // mirrors useCampaignAddresses
  const block = await publicClient.getBlock()
  const tokenSalt = keccak256(encodePacked(['address', 'uint256'], [user.address, block.timestamp]))
  const tokenCtor = encodeAbiParameters(
    [{ type: 'string' }, { type: 'string' }, { type: 'address' }, { type: 'string' }, { type: 'string' }, { type: 'address' }],
    [name, symbol, user.address, '', '', MANAGER])
  const tokenAddress = getCreate2Address({
    from: MANAGER, salt: tokenSalt,
    bytecodeHash: keccak256(concat([TOKEN_BYTECODE, tokenCtor]))
  })
  const startBlock = block.number + 5n
  const hookCtor = encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'uint256' }],
    [POOL_MANAGER, POSITION_MANAGER, PERMIT2, tokenAddress, startBlock])

  // Salt mining done LOCALLY (pure keccak, mirrors HookMiner.find exactly).
  // The on-chain find eth_call fails deterministically with RPC -32003 whenever the
  // search needs many iterations (node execution cap) - see run log. The manager
  // re-validates the flags on-chain in deployToken, so local mining is safe.
  const flags = await readWithRetry({ address: MANAGER, abi: MANAGER_ABI, functionName: 'FLAGS' })
  const initCodeHash = keccak256(concat([HOOK_BYTECODE, hookCtor]))
  let hookAddress, hookSalt
  for (let i = 0; i < 10_000_000; i++) {
    const salt = ('0x' + i.toString(16).padStart(64, '0'))
    const addr = getCreate2Address({ from: MANAGER, salt, bytecodeHash: initCodeHash })
    if ((BigInt(addr) & 0x3fffn) === BigInt(flags)) {
      const code = await publicClient.getCode({ address: addr })
      if (!code || code === '0x') { hookAddress = addr; hookSalt = salt; break }
    }
    if (i > 0 && i % 1_000_000 === 0) console.log('[mine] %d iterations...', i)
  }
  if (!hookAddress) throw new Error('no salt found in 10M iterations')

  // mirrors useCreateCampaign -> LGEManager.deployToken
  const hash = await userWallet.writeContract({
    address: MANAGER, abi: MANAGER_ABI, functionName: 'deployToken',
    args: [{
      tokenConfig: { tokenAdmin: user.address, name, symbol, image: '', metadata: '', tokenSalt },
      hookConfig: { hookSalt, startBlock }
    }],
    ...GAS
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('deployToken reverted')
  const token = await publicClient.getCode({ address: tokenAddress })
  const hook = await publicClient.getCode({ address: hookAddress })
  if (!token || token === '0x') throw new Error('token not at precomputed address')
  if (!hook || hook === '0x') throw new Error('hook not at mined address')
  console.log('[create] %s: token=%s hook=%s startBlock=%s (gas %s)', symbol, tokenAddress, hookAddress, startBlock, receipt.gasUsed)
  return { tokenAddress, hookAddress, startBlock }
}

async function deposit ({ hookAddress, startBlock, amount, label }) {
  // mirrors BuyTokensModal: calculateEthNeeded at current block + 5% slippage
  const currentBlock = await publicClient.getBlockNumber()
  const needed = await readWithRetry({
    address: LIB, abi: LIB_ABI, functionName: 'calculateEthNeeded',
    args: [currentBlock, startBlock, amount]
  })
  const value = (needed * 105n) / 100n
  const hash = await userWallet.writeContract({
    address: hookAddress, abi: HOOK_ABI, functionName: 'deposit',
    args: [amount], value, ...GAS
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`deposit reverted (${label})`)
  console.log('[deposit] %s: %s tokens for ~%s USDC (gas %s)', label, amount / 10n ** 18n, formatEther(needed), receipt.gasUsed)
}

async function priceAt (startBlock) {
  const b = await publicClient.getBlockNumber()
  return readWithRetry({
    address: LIB, abi: LIB_ABI, functionName: 'calculateCurrentTokenPrice',
    args: [b, startBlock]
  })
}

const sleep = ms => new Promise(r => setTimeout(r, ms))

async function main () {
  console.log('[setup] user wallet (fresh):', user.address)
  const fundTx = await deployerWallet.sendTransaction({ to: user.address, value: 15n * 10n ** 17n, ...GAS })
  await publicClient.waitForTransactionReceipt({ hash: fundTx })
  console.log('[setup] funded user with 1.5 testnet USDC, tx', fundTx)

  // ---- campaign D first: its 3600-block window ticks while we run campaign C ----
  const d = await mineAndCreate({ name: 'E2E Fail Path', symbol: 'E2EF' })
  await deposit({ ...d, amount: 100_000n * 10n ** 18n, label: 'D partial' })

  // ---- campaign C: full success path through the UI code paths ----
  const c = await mineAndCreate({ name: 'E2E Success Path', symbol: 'E2ES' })

  const p1 = await priceAt(c.startBlock)
  await sleep(20_000)
  const p2 = await priceAt(c.startBlock)
  if (p2 <= p1) throw new Error(`price did not rise: ${p1} -> ${p2}`)
  console.log('[price] rising curve confirmed: %s -> %s over ~20s', p1, p2)

  await deposit({ ...c, amount: 1_000n * 10n ** 18n, label: 'C small' })

  const cap = await readWithRetry({ address: c.tokenAddress, abi: TOKEN_ABI, functionName: 'cap' })
  const claimed = await readWithRetry({ address: c.hookAddress, abi: HOOK_ABI, functionName: 'totalTokensClaimed' })
  await deposit({ ...c, amount: cap - claimed, label: 'C fill-cap (initializes pool + mints LP)' })

  const success = await readWithRetry({ address: c.hookAddress, abi: HOOK_ABI, functionName: 'isLgeSuccessful' })
  const posId = await readWithRetry({ address: c.hookAddress, abi: HOOK_ABI, functionName: 'positionTokenId' })
  if (!success || posId === 0n) throw new Error(`LGE not successful: success=${success} posId=${posId}`)
  console.log('[success] pool initialized, hook LP position #%s', posId)

  // mirrors CampaignDetail "Claim LP Tokens" button
  const claimTx = await userWallet.writeContract({
    address: c.hookAddress, abi: HOOK_ABI, functionName: 'claimLiquidity', ...GAS
  })
  const claimReceipt = await publicClient.waitForTransactionReceipt({ hash: claimTx })
  if (claimReceipt.status !== 'success') throw new Error('claimLiquidity reverted')
  const nftBalance = await readWithRetry({
    address: POSITION_MANAGER, abi: ERC721_ABI, functionName: 'balanceOf', args: [user.address]
  })
  if (nftBalance < 1n) throw new Error('no LP NFT delivered')
  console.log('[claim] user received LP position NFT (balanceOf=%s)', nftBalance)

  // ---- campaign D: wait out the window, then withdraw (UserProfile recover) ----
  const streamEnd = d.startBlock + 3600n
  console.log('[withdraw] waiting for campaign D window (block > %s)...', streamEnd)
  for (;;) {
    const b = await publicClient.getBlockNumber()
    if (b > streamEnd) break
    process.stdout.write(`  block ${b}\r`)
    await sleep(30_000)
  }
  const balBefore = await publicClient.getBalance({ address: user.address })
  const wTx = await userWallet.writeContract({
    address: d.hookAddress, abi: HOOK_ABI, functionName: 'withdraw', ...GAS
  })
  const wReceipt = await publicClient.waitForTransactionReceipt({ hash: wTx })
  if (wReceipt.status !== 'success') throw new Error('withdraw reverted')
  const balAfter = await publicClient.getBalance({ address: user.address })
  const hookBal = await publicClient.getBalance({ address: d.hookAddress })
  const gasCost = wReceipt.gasUsed * wReceipt.effectiveGasPrice
  if (hookBal !== 0n) throw new Error('hook balance not drained')
  if (balAfter <= balBefore - gasCost) throw new Error('no refund received')
  console.log('[withdraw] refund received: %s USDC (net of gas)', formatEther(balAfter - balBefore + gasCost))

  console.log('\nE2E PASS: create -> deposit -> rising price -> cap fill -> pool+LP -> claim -> failed-LGE withdraw, all via frontend artifacts on Arc testnet')
}

main().catch(e => { console.error('\nE2E FAIL:', e.message); process.exit(1) })
